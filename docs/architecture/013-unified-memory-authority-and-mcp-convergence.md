# ADR 013: Unified Memory Authority and MCP Convergence

## Status

Accepted, 2026-07-04.

## Context

OpenBurnBar ships four related memory surfaces that were designed independently and
documented across multiple plans:

1. **Pensieve** — E2EE cloud knowledge (`docs/PENSIEVE.md`).
2. **Chat-memory authority** — app-owned extraction, quarantine, review, recall over
   `agent_memories(source_kind='chat')` and v51+ integrity tables.
3. **Project Code Memory (PCM)** — daemon-owned code indexing over
   `agent_memories(source_kind='code')` and the v14 search substrate.
4. **Hosted MCP knowledge** — sealed remote tools over Firestore.

An adversarial audit (`docs/MEMORY_STRATEGY_AUDIT.md`) found that a greenfield
`memories`/`memory_embeddings`/`memory_events` design would create a fourth parallel
store and violate the governing thesis in
`docs/PROJECT_CODE_MEMORY_MASTER_PLAN.md` §1:

> Reconcile + extend, not greenfield … not stand up a third parallel memory store.

Separately, the Python stdio MCP server and the Swift daemon both implement schema,
indexing, search, chunking, audit hashing, and project identity — and have diverged in
the past (project id length, fake semantic ranking, write paths). The remediation plan
(`docs/reviews/PROJECT_CODE_MEMORY_MASTER_REMEDIATION_PLAN_2026-06-17.md`) requires one
canonical production engine.

Ground truth as of 2026-07-04 (see `docs/MEMORY_MCP_SOTA_PLAN.md` §0): v51–v54 chat
memory schema, injection safety (`wrapUntrusted` + `PromptTokenArbiter`), all 15 PCM
tools at honest tiers, and PCM hardening checklist items are **shipped on main**. Open
work is activation control, cross-device HMAC, MCP transport convergence, honest
semantic tiers everywhere, MCP management UI, and cross-platform read parity.

## Decision

### One local record authority

- **`agent_memories`** is the single local record table, partitioned by `source_kind`
  (`chat` | `code`). Bodies are sealed-reference only (`body_ref` /
  `memory_body_snapshots`); no plaintext durable body FTS or cloud field.
- **`memory_audit`** is the single hash-chained event log (extend actions, never fork).
- **`memory_embedding_refs`** + v14 `embedding_versions` is the single vector plane
  for chat memory (version + dimension floor enforced at write and read).
- **Pensieve / `cloud_search_knowledge`** is the single cloud plane (cloaked + sealed
  only; vectors local-only by default for chat facts in v1).

No new `memories`, `memory_embeddings`, or `memory_events` tables. CI guard:
`scripts/ci/check-memory-store-invariants.sh` (task B4).

### Authority split (who owns what)

| Layer | Owner | Responsibility |
|---|---|---|
| Canonical engine | Swift daemon | Schema migrations, indexing, search, audit writes, rate limits, `trace_id`, SQLCipher, RPC contracts |
| Chat lifecycle | macOS app (`ControlPlaneStore`) | Extraction outbox, quarantine/review, recall, provenance authority, local forget |
| MCP stdio transport | Python `server.py` | FastMCP façade; **fail-closed** daemon RPC for all writes; dev harness only behind `PCM_DEV_HARNESS=1` |
| Cloud transport | `hosted-mcp` | Sealed-only remote tools; Firestore transactional rate buckets |

### Activation gates (committed product choices)

Resolved per `docs/MEMORY_MCP_SOTA_PLAN.md` §4.1:

1. **Go-live lever:** Remote Config `memory_authority_writes_enabled` ANDed with
   `ControlPlaneStore.chatMemoryAuthorityWritesEnabledByDefault` (compile-time ceiling).
   Owner: Alberto via Firebase console staged rollout.
2. **crossDeviceHMAC:** real HKDF-derived key from vault key (label
   `openburnbar-memory-citation-v1`); `v1-local:` is legacy-read only; cloud sync
   blocked until backfill complete.
3. **Secret/PII policy:** REJECT at both G7 gate points for v1.
4. **Cloud backup:** OFF by default, explicit opt-in.
5. **Approval:** auto-approve nothing; inbox is the sole approval path.
6. **Extraction:** local-only LLM; no cloud transcript egress in v1.

### Platform stance (audit H18)

**macOS/daemon-first, stated honestly.**

- **iOS / Android:** recall via sealed server-side Pensieve `findNearest` + local
  decrypt; no on-device extraction in v1 (separate epic).
- **Windows:** read-only mirror of synced approved facts on the wire-compatible C#
  `CloudVaultCrypto` port; approve/reject remains Mac-owned until a Windows store
  ships.

### MCP SOTA requirements

- 15-tool parity matrix enforced in CI (task D8).
- `trace_id` on every tool response; liveness/readiness split (task D6).
- Per-tool rate buckets; no silent `metadata:standard` fallback on hosted MCP (task D4).
- Remove fake conversation semantic embedding from `server.py` (task D5).
- Hosted code tools remain behind `OPENBURNBAR_HOSTED_CODE_MEMORY_TOOLS` + threat-model
  sign-off (`docs/REMOTE_MCP_THREAT_MODEL.md` Code Asset Class).

### Non-goals (this ADR does not authorize)

- A fourth memory store or plaintext durable memory table.
- Native mobile extraction/embedding.
- Hosted code sync without code asset-class threat-model passage.
- Per-reply cloud LLM extraction for memory.
- Bundled CoreML bge until G6 eval gate clears (`docs/MEMORY_BACKEND_PLAN.md`).

## Consequences

- `docs/MEMORY_BACKEND_PLAN.md` and `docs/MEMORY_FRONTEND_PLAN.md` are **historical
  implementation specs** (implemented on main); status and open work live in
  `docs/MEMORY_MCP_SOTA_PLAN.md`.
- `docs/MEMORY_ACTIVATION.md` must stay aligned with code (G2 default and RC key).
- All memory/MCP implementation PRs follow `docs/MEMORY_MCP_SOTA_PLAN.md` task IDs.
- Supersedes conflicting phasing only where this ADR and the SOTA plan disagree with
  older "greenfield" or "not yet built" claims; `PROJECT_CODE_MEMORY_MASTER_PLAN.md`
  remains authoritative for PCM scope and invariants.

## Related

- `docs/MEMORY_MCP_SOTA_PLAN.md` — execution plan
- `docs/MEMORY_STRATEGY_AUDIT.md` — loophole ledger (§3 of SOTA plan)
- `docs/architecture/012-project-code-memory-embedding-retrieval-policy.md` — dense tier gate
- `docs/PENSIEVE.md`, `docs/REMOTE_MCP_THREAT_MODEL.md`
