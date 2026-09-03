# Memory Pro: big models on the user's own quotas and keys, with BurnBar blind — design

Status: design for review, 2026-09-02. Alberto's brief: "add pro features, cloud and big models, hosted using the user's quotas or OpenRouter or Vercel; super safe, intuitive, encrypted, we must be blind to the data; state of the art." Decisions taken in brainstorming: model calls go direct from the user's Mac to the provider (no BurnBar server in the data path); blind encrypted sync is a separate spec; all four capabilities are in scope, sequenced here.

Builds on the memory engine v2 ([`2026-09-02-memory-mcp-v2-design.md`](../2026-09-02-memory-mcp-v2-design.md), PR #2485) and the 10/10 push ([`2026-09-02-memory-mcp-ten-of-ten-design.md`](2026-09-02-memory-mcp-ten-of-ten-design.md), PR #2498).

## 1. What "Pro" adds

| Capability | Today | With Pro |
|---|---|---|
| Extraction | heuristic cue-word extractor (recall 0.667 on the gold set); Claude CLI and Ollama opt-in | a frontier model extracts facts from the redacted transcript with a structured contract; heuristic remains the fallback |
| Reconciliation | fixed Jaccard/cosine thresholds and regex cues decide ADD / UPDATE / NONE / DELETE | an LLM judge decides the ambiguous cases with a rationale that is stored; rules remain the guardrail and fallback |
| Recall | BM25 + local `nomic-embed-text` + RRF + salience/recency | cloud embeddings (stronger models) and a cross-encoder rerank of the top candidates; local stays the default and fallback |
| Answers | raw memories only; the calling agent reasons | `burnbar_memory_ask`: a grounded answer with citations to memory ids, or an explicit "no evidence" refusal |

Who pays: the user, through their own subscription quota (Claude Code, Codex, via the official CLIs) or their own keys (OpenRouter, Vercel AI Gateway, Anthropic, OpenAI). BurnBar receives nothing, meters nothing, and cannot read anything.

## 2. Non-goals

- No BurnBar-hosted inference or proxy. The only hosted piece of the memory system is the ciphertext-only sync in the separate Blind Sync spec.
- No inference on raw OAuth tokens imported from other apps. Subscription quota is used only through the official CLIs the user already installed and consented to (`claude -p`, `codex exec`).
- No cloud model calls from iPhone or Windows in this release.
- No change to the local-only default. Everything here is off until the user turns it on, and everything degrades to today's local behavior when it cannot run.

## 3. Architecture

```
Claude Code / Codex / Cursor ──stdio──▶ Python MCP (memory engine)
                                            │  no keys, no Firestore
             ┌──────────────────────────────┼──────────────────────────────┐
             │ signed courier                │ loopback HTTP                 │ subprocess
             ▼                               ▼                              ▼
   openburnbar-cli memory-model-policy   daemon gateway 127.0.0.1:8317     claude -p / codex exec
   (what may I use, where, with what     /v1/chat/completions             (user's subscription quota,
    ephemeral token)                     /v1/embeddings  (new)             existing CLI consent)
             │                               │ memory egress policy:
             │                               │ Pro ✓  consent(provider) ✓  no-retention ✓  budget ✓
             │                               │ keys from the daemon Keychain store
             ▼                               ▼
      BurnBar app writes policy         OpenRouter (data_collection: deny) · Vercel AI Gateway (BYOK)
      (consent UI, entitlement)         Anthropic · OpenAI   ← direct from the Mac, user's own key
```

Three principles, each enforced in one place:

1. **The engine never holds a secret.** API keys live in the daemon's Keychain store as today; the engine talks to the loopback gateway with a short-lived, purpose-scoped bearer token from the courier. Subscription quota is used only by spawning the official CLI.
2. **Nothing leaves the device un-gated.** The existing transcript gate (secrets redacted, withheld when unlocalizable) and the raw-form auxiliary gate run before any prompt is built. Prompts wrap memory text as untrusted content. Every model output is parsed against a strict contract and re-gated on write.
3. **Blind by construction, provable.** No BurnBar server is on the path. The daemon writes a content-free `memory.egress` audit event per call (provider, model, purpose, byte counts, retention flag), so "what left the device" is auditable and "who could read it" is answered by the provider's policy, which the daemon requires to be no-retention unless the user explicitly allows otherwise.

### 3.1 Daemon: memory model broker

- **Embeddings route.** `POST /v1/embeddings` on the existing loopback gateway (OpenAI shape), routed to providers that offer embeddings (OpenRouter and Vercel AI Gateway both expose `/v1/embeddings`; OpenAI directly).
- **Memory egress policy** (new config section written by the app, read by the gateway when a request carries `X-OpenBurnBar-Purpose: memory-extract | memory-judge | memory-embed | memory-rerank | memory-answer`):
  - `enabled` (master, default false), `consentedProviderIDs`, `allowedModelIDs` per purpose (empty = provider default), `requireNoRetention` (default true), `dailyCapUSD` (default 2.00), `updatedAt`.
  - Checks, in order, each with its own error code: entitlement (`PRO_REQUIRED`), master switch (`CLOUD_CONSENT_REQUIRED`), provider consent (`PROVIDER_NOT_CONSENTED`), retention (`EGRESS_BLOCKED_RETENTION`), budget (`BUDGET_EXCEEDED`), then the existing provider routing.
  - Retention enforcement per provider: OpenRouter requests get `provider.data_collection = "deny"` and the account-level ZDR preference is required for consent to be accepted; Vercel AI Gateway requests use BYOK credentials and are flagged as "provider-policy applies"; Anthropic and OpenAI direct calls are labelled with their published retention terms in the consent UI. When `requireNoRetention` is on, providers whose retention cannot be asserted are refused.
  - Entitlement: `BurnBarMembershipService` snapshot, ids `burnbar_pro`, `burnbar_pro_max`, `hosted_quota_sync`. The cache is refreshed by the app on launch, on purchase, and daily; the daemon accepts a cache no older than 7 days and otherwise fails closed to free.
  - Audit: `memory.egress` events with provider, model, purpose, request and response byte counts, retention flag, latency, outcome. No content, ever.
- **Courier command** `openburnbar-cli memory-model-policy` (read-only, signed, 20 s timeout like the memory courier): returns `{proActive, enabled, gatewayURL, gatewayToken, tokenExpiresAt, providers: [{id, consented, retention: "deny"|"provider-policy"|"unknown", purposes: {extract: [models], judge: [...], embed: [...], rerank: [...], answer: [...]}}], cli: {claude: bool, codex: bool}}`. The token is minted per call, scoped to `memory-*` purposes, valid 15 minutes. Without the courier (unsigned dev builds) the engine falls back to the daemon socket read the existing code already uses, or to local-only.

### 3.2 Engine: provider layer (`memory_engine/providers.py`)

- `MemoryModelPolicy`: the courier payload, cached in-process for 5 minutes, refreshed on `PRO_REQUIRED`/`CLOUD_CONSENT_REQUIRED` responses. Env overrides exist only for tests (`OPENBURNBAR_MEMORY_MODEL_POLICY_JSON`) and are refused when the process is not a test run.
- `GatewayClient`: OpenAI-compatible chat and embeddings over the loopback gateway; sets the purpose header and bearer; JSON-mode requests; bounded retries with jitter on 429/5xx only; per-purpose timeouts (extract 60 s, judge 20 s, embed 30 s, rerank 20 s, answer 60 s); token and cost accounting from response usage.
- `CLIClient`: `claude -p ... --output-format json` and `codex exec --json --ephemeral --sandbox read-only ...` using the same argument shapes as the app's CLI bridge, with a wall-clock timeout (the app has none; the engine must). Available only when the courier reports the CLI consent.
- `ModelRouter`: picks the client for a purpose from the policy (explicit `provider` argument → policy default → local fallback) and returns a typed result or a typed refusal (`ModelUnavailable(code, reason)`) that callers turn into graceful degradation. Every call site has a local fallback and records what happened in the tool's `trustSignal`.

### 3.3 Extraction v2 (`extract.py`)

- `llm_extract(client, model, gated_transcript, max_facts) -> list[Fact]` with `EXTRACT_PROMPT_VERSION = "openburnbar-memory-extract-v2"`: structured output (`{"facts": [{text, kind, confidence, tags, entities, supersedes_hint, evidence_message_index}]}`), the 12 kinds, calibration guidance, "no secrets, no credentials, no personal identifiers beyond what the policy allows", and untrusted-content framing of the transcript.
- Provenance on every row: `extractor = "llm:<provider>/<model>"`, metadata `extractPromptVersion`, `transcriptGateHash` (hash of the redacted transcript), `modelLatencyMs`. The ingest receipt keeps the same.
- Selection: `burnbar_memorize(extractor="pro")` or the policy default when Pro is enabled; capability `memory_llm_extract` continues to gate argument-selected cloud extraction; the operator env extractor keeps its meaning.
- Fallback: any refusal or parse failure → heuristic extractor, `extractionError` reported, decision unchanged from today.

### 3.4 Reconciliation judge (`_write.py`)

- Seam: after the exact-duplicate shortcut, when candidates exist and either a conflict cue fires or the nearest candidate's similarity lies in the ambiguous band (between `CONFLICT_MIN_SIM` and the dedupe thresholds), `_commit_fact` calls `judge.decide(incoming, candidates[:6])`.
- Contract: `{"event": "ADD"|"UPDATE"|"NONE"|"DELETE", "targets": [memoryID], "rationale": str, "confidence": float}`; the judge sees the gated incoming body and candidate bodies only (no secrets, no vault, no cross-scope rows).
- Guardrails the rules layer keeps: a judge cannot target immutable rows, rows outside the incoming scope, or rows the caller could not otherwise supersede; a `DELETE` requires a target; an out-of-contract answer is discarded and the rules decide.
- Provenance: the decision dict gains `decidedBy: "rules"|"judge:<provider>/<model>"` and `rationale`; both persist in history meta and in the ingest receipt (`INGEST_DECISION_KEYS` extended); the memorize summary keeps its five buckets.
- Budget: at most one judge call per incoming fact; the judge is skipped (rules decide) when the policy is unavailable or the daily cap is reached.

### 3.5 Cloud embeddings and rerank (`embeddings.py`, `_read.py`)

- `GatewayEmbeddingProvider(provider, model)` with `version_id = "gateway:<provider>/<model>:<dim>"`; a provider registry replaces the if-chain; `describe()` names the provider. Bodies are already gated at write, so what is embedded is the stored (redacted) body.
- Switching the embedding provider marks the store as needing `reindex`; `doctor` reports `embeddingPending` and the `burnbar_memory_reindex` tool performs it in batches through the gateway.
- Rerank stage in `recall` after fusion: `rerank: bool | None` (policy default) and `rerank_top_k` (default 20, max 40); a cross-encoder-style scoring prompt (the app's prompt shape, ported) over the top candidates; `why.rerankScore` and `why.reranker`; timeouts or refusals leave fusion order and set `trustSignal.rerank = "skipped:<code>"`. `recall_pack` threads the same arguments.

### 3.6 Ask my memory (`server.py`, `_read.py`)

- Tool `burnbar_memory_ask(question, project_path, scope="all", limit=12, provider=None, min_confidence=0.0)`: recall pack (unwrapped in-process, never returned raw), then an answer prompt with a strict citation contract (`[mem_…]` markers that must resolve to pack ids), refusal when the pack is empty or the model cannot ground the answer.
- Response: `{status, answer, citations: [{memoryID, kind, snippet}], groundedness: "grounded"|"partial"|"refused", model, trustSignal}`; the answer text is wrapped as untrusted content like every model-authored string today.
- Gating: new capability `memory_llm_read` (default on when Pro is enabled), the memory rate limit bucket, and the same egress policy with purpose `memory-answer`. Added to `MEMORY_TOOLSET` and `SKILL.md`.

### 3.7 Consent, intuitiveness, and copy

- Settings → Privacy → Memory gains one section, "Cloud models for memory (Pro)": a master toggle with a consent sheet that states, in plain words, what leaves the device (redacted facts and questions; never raw transcripts, never anything the secret gate caught, never the vault), where it goes (the provider you pick, on your key or your subscription), and what BurnBar sees (nothing). Below it: one row per provider with its retention label and a checkbox; the "only providers that promise no retention" switch (default on); a daily cap; a live status line ("Blind: BurnBar never receives memory data. Provider: OpenRouter, retention: deny").
- The existing memory consent sheet's "Nothing leaves your device" line becomes "Nothing leaves your device unless you turn on cloud models below"; turning the master toggle on requires the new sheet; changing providers does not require re-consent, adding a provider with weaker retention does.
- Remote Config kill switch `memory_cloud_models_enabled` (default true) folded into the master gate the same way the extraction kill switch is today.
- `docs/PRIVACY.md` gains "Optional cloud models for memory (Pro, opt-in)" describing exactly the above and the third-party subprocessor rows for the providers the user can choose.

## 4. Security review checklist (what the tests prove)

- Secrets never reach a provider: the adversarial gate suite gains a fake gateway that records request bodies; every secret shape in every placement must be absent from every request body under extract, judge, embed, rerank, and answer.
- Injection: memory rows carrying injection labels are excluded from judge, rerank, and answer prompts; prompts wrap untrusted content; model outputs that contain pack sentinels or tool-call-like text are refused.
- No key in the engine process: a test asserts the engine's environment and memory contain no provider key material after a full Pro session; the gateway token is single-purpose and expires.
- Fail closed: with the courier absent, the daemon down, Pro inactive, consent off, or the provider refused, every tool returns today's local result plus a `trustSignal` explaining what was skipped; nothing errors.
- Audit: each egress produces exactly one content-free `memory.egress` event, verified against the chain.

## 5. Measured quality (state of the art means numbers)

| Metric | Today | Target with Pro |
|---|---|---|
| Extraction recall on the gold set (36 conversations) | 0.667 heuristic | ≥ 0.85 with a frontier model (measured per provider by `eval_memory.py --extraction --extractor pro:<provider/model>`) |
| Judge agreement with a new gold decision set (64 labelled ADD/UPDATE/NONE/DELETE cases, `eval/judge_gold.json`) | rules: 0.42 (measured 2026-09-03 with lexical similarity; the rules ADD unless a strong cue fires) | ≥ 0.90 with the judge, rules fallback never worse than today |
| Retrieval R@5 / MRR (40 memories, 30 paraphrase queries) | 0.90 / 0.678 local | reported per embedding model and with rerank; rerank must not lower R@5 |
| Answer groundedness on a 30-question set | n/a | ≥ 0.95 of answers cite only existing memories; refusals when no evidence |
| Secret leakage to the fake gateway | n/a | 0 across the adversarial suite |

## 6. Rollout

Off by default, behind Pro and consent; providers appear only when a key or CLI consent exists. Ships as one PR per subsystem in this order: daemon broker + courier; engine provider layer + extraction + judge; embeddings + rerank; ask; consent UI + privacy docs. Each PR is independently green and reviewable; the feature becomes visible to users only with the last one.

## 7. Open questions resolved by default (change them if you disagree)

- Daily cap default $2.00, matching the existing hosted-insights ceiling.
- Judge only on ambiguous cases, not every write, to keep latency and spend bounded.
- OpenRouter consent requires the account-level ZDR setting when "no retention only" is on; the UI explains how to set it.
- iPhone and Windows keep local-only recall in this release.
