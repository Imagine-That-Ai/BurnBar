# Usage Memory — design delta (v1: local-only)

**Status:** program in flight. This is the reconciling design doc for the
usage-memory program — the delta against the shipped chat-memory subsystem
([`MEMORY_BACKEND_PLAN.md`](MEMORY_BACKEND_PLAN.md),
[`MEMORY_ACTIVATION.md`](MEMORY_ACTIVATION.md)) and against Pensieve's hosted
knowledge lanes ([`PENSIEVE.md`](PENSIEVE.md)). It is a reviewer's map: what is
new, what is deliberately reused, the one hard v1 invariant, and where each
piece landed (or will land).

## Mission

Usage memory turns two passive exhausts the member already produces — Safari
asks they volunteered (prompt + page identity + answer digest, never browsing
history) and recorded agent-session rollouts — into durable, consent-gated,
reviewable memories, using the SAME authority substrate, secret gate, review
lifecycle, and forget machinery chat memory already ships. v1 is **fully local
by default**: mining, curation, and storage all run on device; cloud curation is
a separately-consented, metered, provider-pinned option; and **no usage memory
replicates to any cloud lane at all** (the invariant below).

## What this adds vs MEMORY_BACKEND_PLAN.md / PENSIEVE.md

**New source kinds on the ONE authority table — not a new store.**
`MemorySourceKind.safariAsk` (`safari_ask`) and `.agentSession`
(`agent_session`) land as rows in the existing `agent_memories` authority table
(PR1). The ControlPlaneStore authority CRUD is parameterized by source kind;
chat call sites keep byte-identical behavior via forwarding wrappers (pinned by
`UsageMemorySourceKindTests`). Usage kinds share a `usage:` storage partition
(dedup and corroboration work across the two sources) and are source-kind-guarded
from chat rows in both directions. Sealed body snapshots gain an optional
extraction-context field (schemaVersion 2; chat stays v1 byte-identical). The
G7 secret/PII gate, quarantine-on-write, audit trail, and tombstone machinery
are inherited, not reimplemented.

**A Stage 0–3 funnel in front of the authority table.**
- **Stage 0 — zero-LLM candidate gate** (PR3): pure structural drops → G7
  secret/PII (fail-closed) → junk filters → policy-weighted salience, plus
  SimHash near-dup collapse. Survivors spool into `memory_usage_candidates`
  with content-derived ids (re-mining is idempotent). Page and session text is
  data, never prompt.
- **Stage 1 — LLM curation** (PR6): batched candidates → atomic-note extraction
  on the placement the member chose (local by default; metered cloud lanes
  below).
- **Stage 2 — quarantined authority writes** (PR7): extracted notes become
  `usage:`-partition `agent_memories` rows, always `quarantined`, through the
  same single write choke point chat uses.
- **Stage 3 — consolidation** (PR8/9): salience decay and typed links
  (`near_duplicate | contradicts | supports | promoted_from`) over the sidecar
  tables, promotion of corroborated facts.

**Sidecar tables, not ALTERs** (PR2, migration `v61_usage_memory`):
`memory_usage_candidates` (Stage-0 spool, payload sealed inside SQLCipher),
`memory_salience` (salience sidecar — deliberately NOT an ALTER on
`agent_memories`, so the app/daemon/python/doc mirror set of that table stays
untouched), `memory_links` (typed consolidation edges), and
`memory_extraction_jobs.source_kind` (default `'chat'` backfill).

**A consent lattice of its own (G0-U), stricter than chat's** (U1). Everything
defaults dormant: `usageMemoryConsentGranted` default **false** gates
extraction; `usageMemoryCloudCurationConsentGranted` default **false** AND
placement default **`.local`** make cloud curation triply false out of the box.
Two Remote Config fleet kills back it: `memory_usage_extraction_enabled` and —
new relative to the chat lane, which has no runtime authority-write kill —
`memory_usage_authority_writes_enabled`, wired as a second kill-switch lane
(`UsageMemoryKillSwitchRegistry`) so the fleet can halt usage WRITES instantly
without touching extraction or the chat lane. Per-source toggles
(`usageMemorySourceSafariAsksEnabled` / `usageMemorySourceAgentSessionsEnabled`)
are inert until consent opens.

**Two-tier metered cloud curation, provider-pinned** (U4 server, U5 client).
All cloud curation inference flows through ONE entitlement-gated callable,
`curateUsageMemoryBatch`, which calls OpenRouter with the provider pin
`{order: ["CoreWeave"], allow_fallbacks: false, data_collection: "deny",
zdr: true}` — a privacy decision, not a performance choice: member page/session
text must not reach arbitrary or Chinese-operated inference providers, provider
data collection is denied, and zero-data-retention endpoints are required. Text
lane (`deepseek/deepseek-v4-flash`) is available to **all active Pro tiers**;
the multimodal M3 lane (`minimax/minimax-m3`) requires **`pro_max`** (Ultra
mirrors Pro Max). Server-side metering is transactional
reserve-before/settle-after against `users/{uid}/usageCurationAllowance`
(monthly + daily token meters per lane, RC-tunable, ultra multiplier); the
client adds a belt-and-braces daily USD ledger and a pure model router whose
exhaustive sweep proves no gate-closed/budget-spent combination can produce a
cloud route.

**Fully-local placement is the default.** With placement `.local`, curation
runs on the member's Ollama: text via the existing local model default
(`qwen3.5:9b`), images via `usageMemoryLocalVLModel` (default `qwen3-vl:8b`;
empty string = images skipped). Local-first is why the funnel exists: Stage 0's
gate holds the LLM load to a few batches a day (numbers below), small enough
for local models.

**Safari surface is permission-pinned** (U0): the extension manifest is
validated to an exact permission set with `history` explicitly forbidden —
usage memory derives from asks the member volunteered, never browsing history.

## The v1 replication invariant

**Usage memories are LOCAL-ONLY in v1.** They must never reach either cloud
lane:

1. **Sealed-facts lane** — `users/{uid}/memory_facts`
   (`MemoryCloudSyncService.syncApprovedMemories`): the candidate query
   `cloudSyncCandidateChatMemories` routes through
   `fetchActiveChatMemoryAuthorityRecords`, which is parameterized to
   `sourceKinds: [.chat]` — usage rows are structurally excluded, not filtered
   by a flag. Pinned by
   `AgentLensTests/Active/UsageMemoryCloudSyncInvariantTests.swift`
   (store-level exclusion + an end-to-end `MemoryCloudSyncDomain.sync()` run
   with every chat-lane lever open).
2. **Cloaked-vector lane** — `users/{uid}/cloud_search_knowledge`
   (`commitKnowledgeBatch` in `functions/src/callables/knowledgeMemory.ts`):
   the `SOURCE_KINDS` allowlist is exactly
   `{repo_docs, notes, chat_memory, code}`; `requireSourceKind` rejects
   `safari_ask` / `agent_session` on every write path. Pinned by
   `functions/src/__tests__/usageMemoryReplicationInvariant.test.ts`.

**Why:** per-vector cloud forget receipts do not exist yet.
`cloud_search_knowledge` supports only source-level deletes
(`deleteKnowledgeSource`); forget receipts exist only for the vectorless
`memory_facts` lane. A replicated usage vector would be a cloud row the member
cannot provably forget one memory at a time. Replication of usage memories is
therefore **BLOCKED until that gap closes** — and both pins above are written
so that closing it must be a conscious, reviewed decision, not a drive-by
allowlist edit.

(Note the boundary: cloud *curation* (U4/U5) sends candidate batches through a
metered, pinned, zero-retention inference call and stores nothing server-side;
cloud *replication* would store derived memories in Firestore. The invariant
blocks the latter only — the former is separately consented and stateless.)

## Program map

| Step | PR | What |
|---|---|---|
| PR1 | [#2257](https://github.com/Imagine-That-Ai/BurnBar/pull/2257) | Source-kind parameterization; `safariAsk`/`agentSession` on the authority table; chat byte-identity pins |
| PR2 | [#2259](https://github.com/Imagine-That-Ai/BurnBar/pull/2259) | `v61_usage_memory` migration pair: candidate spool + salience/links sidecars + jobs column |
| PR3 | [#2260](https://github.com/Imagine-That-Ai/BurnBar/pull/2260) | Stage-0 zero-LLM candidate gate, SimHash, versioned curation policy, real-corpus harness |
| U0 | [#2258](https://github.com/Imagine-That-Ai/BurnBar/pull/2258) | Safari extension permission pin — `history` forbidden |
| U1 | [#2262](https://github.com/Imagine-That-Ai/BurnBar/pull/2262) | Consent lattice G0-U: settings, pure gates, two RC kill lanes, dormant by default |
| U4 | [#2261](https://github.com/Imagine-That-Ai/BurnBar/pull/2261) | `curateUsageMemoryBatch`: metered, entitlement-gated, CoreWeave-pinned curation gateway |
| U5 | [#2263](https://github.com/Imagine-That-Ai/BurnBar/pull/2263) | Cloud client + model router + client spend belts + local VL support |
| U8 | this branch | Executable replication invariant (both lanes) + this doc |

PR3's real-corpus evidence sizes the funnel: a full pass over the live
`~/.codex/sessions` corpus — **14.52 GB, 5,893,576 events** — gated down to
**6,467 accepted candidates over 21.4 days ≈ 303/day** (0.11% of raw events),
projecting ~20 extraction calls/day at ~15 candidates/batch for an extreme
power-user corpus.

**Remaining planned steps:** PR4 rollout miner (reusing PR3's payload-shape
normalization), PR5 Safari ask tap, PR6 extraction cadence (Stage 1), PR7
Stage-2 authority writes, PR8/9 consolidation (salience decay, links,
promotion), PR10 acceptance harness, U2/U3 consent UI + local-model setup, U6
Safari consent copy, U7 inbox review chips.

## Non-goals (v1)

- No usage-memory replication to any cloud store (the invariant).
- No browsing-history capture, ever (U0 pins the manifest).
- No new authority store, no schema forks of `agent_memories`.
- No self-tuning outside `UsageMemoryCurationPolicy`'s versioned knob record —
  consent and egress boundaries are structurally outside the tunable surface.
