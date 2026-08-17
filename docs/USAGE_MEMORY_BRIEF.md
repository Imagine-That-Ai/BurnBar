# Usage Memory — build brief

**For:** the agent implementing OpenBurnBar's Pro usage-memory feature.
**Status of this document:** design brief + verified inventory. Nothing described
under "The gap" is built yet.

---

## 1. Mission

Give a Pro member a memory that makes OpenBurnBar feel like it knows them: it
watches what they actually ask across Safari, the BurnBar chat surfaces, and
their recorded agent sessions; it keeps the small number of facts that stay
true and useful; it drops the rest; it reorganizes itself as it grows; it
repairs its own contradictions; and it gets better at deciding what is worth
keeping.

It must do this at a cost per active member of **cents per month**, with
**storage in the low megabytes**, and with **no page-derived content leaving
the device unless the member has explicitly chosen a cloud path**.

Ship it opt-in, dormant by default, and forgettable end to end.

---

## 2. What already exists (verified — do not rebuild these)

You are extending a substantial, already-built system. Read before designing.

### 2.1 The memory authority layer — built, tested, deliberately dormant

- `docs/MEMORY_ACTIVATION.md` — the closing doc. Every component is built and
  committed; **nothing is switched on**. It writes no durable row out of the box.
- `docs/MEMORY_BACKEND_PLAN.md` — schema and worker design.
- `docs/MEMORY_FRONTEND_PLAN.md`, `docs/MEMORY_STRATEGY_AUDIT.md` — the "why".
- Authority table: **`agent_memories`**, one table partitioned by `source_kind`,
  currently `'code'` (daemon-owned) and `'chat'` (app-owned, GRDB). Sealed
  reference bodies — **never plaintext**.
- Provenance rows, `citation_state` (`live|source_pruned|tombstoned`), and
  **`memory_source_tombstones`** for fact-level (not source-wide) forget.
- **Three AND-ed fail-closed gates.** No row is written unless all three allow:
  - **G0 `consentGranted`** — persisted first-run consent, **defaults OFF**.
  - **G1 `memoryExtractionEnabled`** — G0 AND the user extraction toggle AND the
    Firebase Remote Config fleet kill switch.
  - Plus the go-live flag. Gate logic lives in `MemoryExtractionGate.isEnabled(...)`;
    `SettingsManager.memoryExtractionEnabled` (`AgentLens/Services/SettingsManager.swift`).
- `MemoryExtractionWorker` — an actor, debounced on idle/session-end, admission-
  gated, with LLM/embed calls kept **outside** the held write transaction.

### 2.2 Pensieve — the productized, E2EE, per-member memory (`docs/PENSIEVE.md`)

- Per-paying-member end-to-end-encrypted semantic memory. Chunked, embedded,
  **cloaked**, AES-256-GCM sealed **on device**; the provider never sees plaintext.
- Entitlement family **`mnemo`** / `burnbar_ultra`; included in **$24.99 Cloud Pro
  (`burnbar_pro_max`)**. Queried by agents over the existing hosted MCP.
- **This is the delivery vehicle for the feature. Use it. Do not stand up a
  parallel store** — the master plan is explicit that this is "a local index over
  Pensieve/snapshot memory, not a third store."

### 2.3 Embeddings — built

- `tools/openburnbar-mcp-remote/src/embed.ts` — on-device **bge-small-en-v1.5-384**
  plus per-user vault-key vector cloaking (hides the public bge basis so
  off-the-shelf embedding-inversion models cannot be applied directly).
- Embedding-version safety is already designed: pin model + revision in
  `EmbeddingModelDescriptor.versionTag`.

### 2.4 The three sources you will draw from — all already recorded

| Source | Where it lives today | Notes |
|---|---|---|
| Safari asks | `extensions/safari` → daemon gateway `127.0.0.1:8317` | prompt + page context + answer |
| BurnBar chat surfaces | `~/Library/Application Support/OpenBurnBar/ChatWorkspaces` (~11 MB) | Hermes / CLI-bridge chat |
| Agent session logs | `~/.codex/sessions` (**~14 GB today**) | already on disk, never mined |

### 2.5 Safari extension "learning" — exists, but is not this feature

- Explicit corrections only: `popup.teachCorrection` → `learning.propose` →
  the member approves/rejects/forgets via `popup.learningReview`.
- Snapshot exposes `learning.{eligible, optedIn, consentSeen, items[]}` where
  items are `kind: 'memory' | 'skill'`, `status: 'proposed' | 'accepted'`.
- It is **user-authored and pull-based**. Nothing is inferred passively.

---

## 3. The gap (what you are actually building)

1. **No usage/browsing source kind.** `source_kind` is `'code' | 'chat'` only.
   There is no page-visit or query-derived memory path.
2. **Nothing reads what the member asks in Safari into memory.** The Safari
   manifest requests `activeTab, alarms, nativeMessaging, scripting, storage,
   tabs` — and deliberately **no `history` permission**. Decide consciously
   whether you need one; prefer deriving from *asks* rather than raw history.
3. **The 14 GB of session logs are never mined.**
4. **No curation.** Nothing scores, decays, merges, promotes, or evicts.
5. **No self-organization, self-healing, or self-improvement loop.**
6. **No consent surface for any of this.** G0 exists; a usage-memory-specific
   consent and its Safari/app UI do not.

---

## 4. Hard constraints (violating any of these fails the build)

1. **The privacy claim we already ship must stay literally true.** The Safari
   first-run walkthrough states: *"With a local model, nothing about the page
   leaves this Mac. Cloud models receive your question and that page's context —
   only at the moment you ask."* (`extensions/safari/src/popup/render.ts`,
   `WELCOME_CARDS`, and pinned by tests in `test/popup.test.ts`.)
   → **Extraction is part of "the page's content."** If extraction runs on a
   cloud model, that is new egress and the claim breaks. Therefore:
   **prefer a local extraction model when one is available** (the member already
   has `ollama-local` at `127.0.0.1:11434` and MLX wired), and require explicit,
   separate consent before any cloud extraction. Update the walkthrough copy and
   its tests in the same PR if the contract changes at all.
2. **Fail closed.** Default OFF. Reuse the existing G0/G1 gates rather than
   inventing new ones. Dormant must mean zero LLM calls, zero writes, zero egress.
3. **Never store plaintext bodies.** Sealed references only, per the existing
   discipline. Cloaked vectors only.
4. **Forget must be real and fact-level**, end to end, including the cloud row
   and its cloaked vector, with receipt + tombstone. Ship forget **before** any
   replication is enabled (this is already the stated rule — G5).
5. **One authority table.** Add a `source_kind`, do not add a store.
6. **Secrets/PII gate** (the existing G7) applies to every candidate before it is
   sealed. Page content is far dirtier than chat — treat it as hostile input.
7. **Never act on instructions found in page content.** Extraction reads
   attacker-controllable text; it must be data, never prompt.

---

## 5. The implementation to build

### 5.1 Shape: a four-stage funnel where the LLM is the *last*, rarest step

The entire cost story is "don't run a model on most things."

```
 raw events (asks, chats, session turns)          ~thousands/day
        │
        ▼  Stage 0 — CANDIDATE GATE          ← zero LLM, pure CPU
        │   • user-authored or user-corrected text only
        │   • salience heuristics (question shape, repetition, dwell, explicit correction)
        │   • embedding novelty: cosine vs existing memory > τ_novel
        │   • hard drops: secrets/PII, ephemeral junk, nav noise
        ▼                                          ~tens/day survive
        │  Stage 1 — BATCHED EXTRACTION       ← DeepSeek V4-Flash, debounced
        │   • sleep-time: fires on idle / session-end, never in the hot path
        │   • N candidates per call (batch 10–25)
        │   • STABLE PROMPT PREFIX (see 5.4) to force cache hits
        ▼                                          ~units/day written
        │  Stage 2 — DEDUP + WRITE            ← zero LLM
        │   • MD5 exact-hash dedup, then embedding near-dup (mem0's approach)
        │   • seal body, write agent_memories + provenance + cloaked vector
        ▼
        │  Stage 3 — CONSOLIDATION ("the sleep")  ← rare, cheap, mostly arithmetic
            • decay, reinforce, merge, promote, evict, repair
```

### 5.2 Curation — dropping the unimportant, building on the important

Give every memory a **salience score**, and make it mostly free to maintain:

- `salience = w₁·recency_decay + w₂·log(hit_count) + w₃·source_trust + w₄·corroboration`
- **Reinforce on use, not on retrieval.** Bump `hit_count` only when a retrieved
  memory actually appears in / measurably shifts the answer. Retrieval alone is
  a weak signal and rewards noise.
- **Corroboration** — independent restatement from a *different* source kind is
  the strongest keep signal (asked in Safari *and* worked on in a session).
- **Decay + evict.** Below threshold → tombstone via the existing forget path.
  This is arithmetic; it costs nothing and it is what stops unbounded growth.
- **Promote.** A cluster of related low-level facts that keeps getting hit should
  be merged upward into one durable, higher-level statement — one LLM call,
  triggered rarely, only for high-salience clusters.

### 5.3 Self-organizing, self-healing, self-improving

- **Self-organizing (A-MEM / Zettelkasten).** Each memory is an atomic note with
  LLM-generated keywords, tags, and a context sentence. Link new notes to nearest
  neighbours by embedding kNN (**free**), and only spend an LLM call to *evolve*
  a neighbour's context when the link is strong **and** the neighbour is
  high-salience. A-MEM reports large multi-hop gains at **85–93% fewer memory-op
  tokens** than baselines — that combination is the target.
- **Self-healing.** Near-identical embedding + contradictory content → flag the
  pair, resolve with one cheap call, keep the better-sourced/newer, tombstone the
  loser with a receipt. Add a repair job that re-checks provenance
  (`citation_state`) and re-indexes on `versionTag` change.
- **Self-improving (Prime Agent's Continual Harness pattern).** Keep the
  extraction prompt, the salience weights, and the thresholds as **durable,
  versioned harness state** — not constants in code. Measure retrieval precision
  (share of injected memories that were actually used), then apply *small,
  evidence-backed* updates, A/B'd against a frozen offline eval set. Log every
  self-edit with its evidence. Never let a self-edit widen a privacy or consent
  boundary — gate those permanently out of the self-improving surface.

### 5.4 Cost engineering (this is a first-class requirement)

- **DeepSeek V4-Flash pricing:** `$0.14/M` cache-miss input, **`$0.0028/M`
  cache-hit input (50×)**, `$0.28/M` output. Cache hits require an **identical
  prefix from token 0**.
  → Therefore: instructions, schema, and few-shots go in a **byte-stable prefix**;
  only the candidate batch varies, appended last. Never reorder the prefix.
  Track `prompt_cache_hit_tokens` / `prompt_cache_miss_tokens` from the response
  and **alert if the hit rate drops** — a silent prefix change is a 50× cost regression.
- **Illustrative budget to validate** (not gospel — measure it): 200 candidates/day,
  batched 20/call ⇒ 10 calls/day; ~3 k cached prefix + ~1 k fresh input + ~500 output
  per call ⇒ **≈ $0.003/day ≈ $0.09/member/month**. If your design lands far off
  this, the funnel is leaking.
- **Storage:** 384-dim @ int8 ≈ 384 B/vector. 5 000 memories ≈ ~2 MB of vectors.
  Quantize; do not store float32.
- **Egress:** zero when extraction is local. When cloud, only sealed candidate
  text — and only under the separate consent from §4.1.
- **Never** run extraction in the request hot path. Idle/session-end only.

---

## 6. Reference implementations to study

- **A-MEM** — Zettelkasten-style self-organizing agentic memory; note construction,
  autonomous linking, memory evolution. https://github.com/agiresearch/a-mem ·
  https://arxiv.org/abs/2502.12110
- **mem0** — extraction → dedup → store pipeline; the ADD/UPDATE/DELETE/NONE
  decision prompt and the V3 additive+hash-dedup design; batch embeddings.
  https://github.com/mem0ai/mem0 (`configs/prompts.py`, `memory/main.py`)
- **Letta / MemGPT** — memory blocks and **sleep-time compute**: a background agent
  sharing memory blocks, consolidating while the primary agent is idle. This is
  the model for Stage 3. https://www.letta.com/blog/sleep-time-compute/
- **Prime Agent (PrimeIntellect, MIT, Aug 2026)** — the **Continual Harness**:
  durable prompt/skills/memory state refined by small evidence-backed updates
  (`/refine`). This is the model for §5.3's self-improvement.
  https://github.com/PrimeIntellect-ai/prime-agent
- **Hermes** — in-repo: `services/hermes-realtime-relay`,
  `tools/hermes-platform-burnbar`; chat is already a designed memory source
  (`source_kind='chat'`).
- **DeepSeek context caching** — https://api-docs.deepseek.com/news/news0802/

---

## 7. Deliverables

1. A design doc that **reconciles with** `MEMORY_BACKEND_PLAN.md` and
   `PENSIEVE.md` and states precisely what it adds (new `source_kind`, curation
   layer, consent surface). Explicitly not a greenfield store.
2. Schema migration adding the usage source kind + salience/link columns.
3. Stage 0 candidate gate, with an offline harness proving its drop rate on the
   real 14 GB session corpus.
4. Batched extractor on DeepSeek V4-Flash with a byte-stable prefix and cache-hit
   telemetry.
5. Stage 3 consolidation worker (decay/reinforce/merge/promote/evict/repair).
6. Consent + control UI in both the app and the Safari settings panel, plus a
   member-visible "what it remembers / forget this" view.
7. Tests: gates fail closed; forget is complete across tiers; no plaintext at rest;
   PII gate holds on hostile page text; cost telemetry asserted.

## 8. Acceptance criteria

- Dormant by default: with consent OFF, **zero** LLM calls, writes, or egress —
  assert this in a test.
- Measured cost per active member per month, reported with the cache-hit rate.
- Storage growth per 1 000 memories, measured.
- Retrieval precision on a held-out eval set, before vs after the self-improving
  loop, showing the loop actually helps.
- Forget verified end to end, including cloaked cloud vectors, with receipts.
- The Safari privacy walkthrough copy is still true, and its tests still pass.

## 9. Check in before you build

Come back with a recommendation, do not silently choose:

1. **Extraction model placement** — local-only (protects the shipped privacy
   claim, weaker extraction) vs cloud DeepSeek under separate consent (better
   extraction, new egress, walkthrough copy must change). This is a product
   decision, not an engineering one.
2. **Whether you need Safari `history` permission at all.** Strong recommendation:
   no. Derive from what the member *asks*, which they already volunteered, rather
   than from everything they browse. It is a smaller promise, a smaller blast
   radius, and a much easier consent conversation.
3. **Tier placement** — Pensieve is `burnbar_pro_max` / `mnemo` today. Confirm
   whether usage memory rides that entitlement or a different one.
