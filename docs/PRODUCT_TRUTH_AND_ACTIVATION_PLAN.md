# BurnBar — Product Truth & Activation Plan

**Date:** 2026-08-16 · **Supersedes the thesis in** [`PRODUCT_FOCUS_AND_ONBOARDING_PLAN.md`](PRODUCT_FOCUS_AND_ONBOARDING_PLAN.md) (its five bug findings and market research still stand; its "quota meter is the product" conclusion does not).

**Method:** 40 agents across three sweeps — a 196-feature inventory, a memory/corpus/MCP re-rank, and a claim-by-claim fact-check against source. Every finding below was re-verified by hand.

---

## 1. The one-sentence diagnosis

**BurnBar's problem was never too many features. It's that the product is asleep.**

A fresh install captures nothing, routes nothing, analyzes nothing, and remembers nothing. Indexing, memory, the gateway, the inbox and egress **all default to off, each one test-locked.** That is an excellent privacy posture and a nonexistent activation story.

Then three wires between the subsystems are cut, so even with every switch thrown, the loop does not close.

The result: **nobody has ever seen this product run end to end — including the person who built it.** That is why it reads as 196 disconnected features. They *are* disconnected, today, in code.

This is good news. The expensive work is done. What is missing is connective tissue, four switches, and one placeholder swap.

---

## 2. What the product actually is

Four verbs, one loop:

| Verb | What it does | State |
|---|---|---|
| **WATCH** | Cross-vendor quota + spend across 37 providers | **Shipped and on** — the only leg that works out of the box |
| **REMEMBER** | Local transcript archive across 28 agents → curated durable facts | Shipped, **off by default**, and extracting from the wrong table |
| **ROUTE** | Local gateway picks the account whose window survives | Shipped, **off by default**, and better than we've been claiming |
| **DECIDE** | AI Inbox: the one next move, in a founder's voice, with receipts | Shipped, **off by default (twice)** |

**The wedge is the three-way join**, and it is genuinely unoccupied: full-fidelity transcripts from 28 agents **+** token-level cost for each **+** the repo/CI outcome that says whether the thing worked.

- SpecStory, Pieces, Lore — transcripts, **no cost data**
- DX, Faros, ccusage, CodexBar — cost, **no transcripts**
- mem0, Zep, Letta, Cognee — **neither**; they're substrate sold to app builders
- Anthropic, Cursor, OpenAI — one vendor only, and cross-agent memory is a **defection tool** that lowers switching costs away from them. They will never build it. That boundary holds because closing it is against their commercial interest.

**The AI Inbox is the only component that already touches all three legs** — `BurnBarAIInboxWorkspaceScout` reads worktrees, `BurnBarGitHubCLIClient` reads PRs, the promised-not-landed detector joins a session's *claim* to a *commit*, the cost-anomaly detector joins spend. That is why it's the surface the product should be sold on, not a feature inside it.

**The artifact that proves all of it** — and that no competitor can produce:

> *You solved these 7 problems more than once, across 4 agents. Re-deriving them cost you $340.*

It requires joining transcripts to token spend, which nothing does today. It is simultaneously the acquisition demo, the pricing justification, and the retention argument.

---

## 3. Corrections to my own earlier claims

| I said | Truth |
|---|---|
| "96.5% gross margin — capped inference verified" | **Wrong, and my error.** I read `CLOUD_DAILY_BASE_COGS_USD` as if it were the model. It's a constant the dashboard never reconciles against the unit costs sitting in the same file. Real margin is **55–67%**. Worse: `insightsHostedAnswer` — the one path where BurnBar genuinely pays for inference on its own OpenRouter key — **has no meter at all**, only a 200/day rate limit ≈ **$13/mo of spend against $6.79/mo net revenue**, and it writes no usage record so the COGS pipeline can't see it. |
| "Quota-aware routing verified — the loop is closed" | **Right, and it's better than I said** — see §5. But the gateway is **off by default**, daemon-side quota freshness is broken (§4.6), it's **reactive not predictive**, and **Cursor does not route** — `wire` throws for `.cursorAgent`. Six clients do: Claude Code, Codex, OpenCode, Forge, Factory Droid, Grok Build. |

---

## 4. The eight gaps, ordered by how much they block the pitch

**4.1 — MCP cannot open the database.** The app enforces SQLCipher at rest; `tools/openburnbar-mcp/server.py:184` opens the same file with stock `sqlite3` and no key. Verified against the live 5.5 GB store: `DatabaseError: file is not a database`. **29 of 68 tools dead** — every conversation-search and memory-recall tool, i.e. exactly the ones the pitch is about. `burnbar_resolve_db_path` still reports `exists:true`, so the server looks healthy while returning nothing. Every Python fixture builds a *plaintext* DB, so CI is blind. The server's own comment at `:3166` predicted this.

**4.2 — MCP has no distribution.** Zero files in the Mac app write an MCP config for any client. The npm shim is unpublished. Local install needs a repo clone plus a Rust toolchain. Meanwhile BurnBar already writes **eight** agent config formats safely for the gateway — that machinery was simply never pointed at MCP.

**4.3 — Memory never reaches the agents, and extracts from the wrong table.** `ChatTranscriptExtractor.fetchChatTranscriptForExtraction(threadID:)` reads `chat_messages` — BurnBar's own chat panel — never `conversations`, where all 28 providers land. **We ingest 28 agents' sessions and extract memory from none of them.** Recall is likewise scoped to BurnBar's own composer. Combined with 4.1, the corpus has exactly one consumer: BurnBar itself.

**4.4 — The default install does nothing.** Five gates, all off, all test-locked, with no guided path through them. Whoever owns onboarding owns the entire revenue risk.

**4.5 — The embedder is a hash.** `IndexSettings.swift:28` defaults `indexEmbeddingProvider` to `.deterministic` = `DeterministicFakeEmbeddingProvider` — 96 dims from `sha256Hex()`. The type has **"Fake" in its name**; the settings UI calls it **"OpenBurnBar Local."** Reorder the same words: cosine similarity 1.0 → 0.17, against a 0.11 noise floor. HNSW is doing real ANN over a meaningless space and RRF is fusing BM25 with noise. **Real Apple sentence embeddings (`NLEmbeddingProvider`) exist 80 lines below in the same file**, wired only to the memory lane. This is a one-line enum case plus a re-embed. **Fix this before marketing anything about search or memory** — the market has priced untrustworthy memory at $0 four separate times.

**4.6 — Quota freshness never reaches the router.** `applyProviderCredentialSlotQuotaRefresh` has exactly two callers, both in the Provider Plan wizard. No background timer pushes fresh provider-API quota into the daemon; the app's 15-minute refresh loop only updates in-app UI. The router therefore learns quota mostly from response headers and failures.

**4.7 — Two of three top-up meters are unspendable.** `reserveAgentControlActionBudget` and `reserveFlooRelayBudget` have **zero callers in any client**. Buying those packs credits units nothing debits. Only Elder Wand search packs are consumable end to end. **Do not sell the other two.**

**4.8 — The founder's voice is advice, not enforcement.** The doctrine packs and ban list are snapshot-locked constants injected into prompts, but `violations(in:)` **has no production caller** — nothing checks the output. And the zero-egress rule-based path never sees the packs at all, contradicting its own docstring. Another subsystem in this repo already enforces a ban list at runtime; the inbox just doesn't call it.

**Also cheap and load-bearing:** the primary action on the inbox's flagship finding is titled *"Resume this session"* and opens a log — that's the single click at the end of the product's best story. The mission console's "fleet" is a **hardcoded four-element array with `availability: .online` compiled in**, progress bars are constants by state (planned 0.05 / running 0.35 / partial 0.7), and when the daemon is unreachable it renders a **synthesized** mission. Do not demo that screen until it's real.

---

## 5. The biggest positive surprise

**Quota-driven routing is not marketing — it's the real serving path, and it's better than we've been claiming.**

The daemon gateway filters every credential slot through persisted quota state (`.exhausted` / `.coolingDown` / stale-retry) **before any bytes go upstream**, then orders survivors by drain-soonest-reset *ahead of* its own five-dimensional scorecard, then fails over account-to-account **mid-request** on 402/429/401/403 and writes the failure back so the next request skips the dead slot.

It has end-to-end gateway tests per client wire shape. It has carve-outs that prove someone actually used it in anger — an Anthropic OAuth slot is deliberately *not* poisoned by a model-scoped 429. And it **fails closed rather than quietly downgrading your model**, with named tests asserting the refusal.

Runner-up: the consent architecture. Every gate off, each test-locked with an explanatory assertion; the memory extractor endpoint-pinned to loopback before any transcript egress; P1 push carries only an item id because the Cloud Function holds no vault key.

> Most companies claim privacy and ship telemetry. This one shipped the gates and forgot to tell anyone the product is asleep.

---

## 6. The pitch, with every word defensible today

Words deliberately absent: *every, all, fleet, live, diffs, workflows, cheap models, capped inference, MCP.*

> **BurnBar is a local-first control layer for the coding agents you already run.** Everything below is a switch you throw.
>
> **Routing.** Turn on the local gateway and connect a CLI — Claude Code, Codex, OpenCode, Forge, Factory Droid or Grok Build — and BurnBar routes each request across your own provider accounts: it skips accounts that are out of quota or cooling down, prefers the account whose window resets soonest, and fails over mid-request when a provider returns a quota, rate-limit or auth error. Adding a second account is all the configuration there is. It never substitutes a different model than the one you asked for; when your exact model is exhausted everywhere, it fails closed and tells you.
>
> **Transcripts.** Turn on indexing and BurnBar builds a local, searchable archive across 28 coding agents — every user and assistant turn, with timestamps, project, working directory, and the files, commands and tools each session touched. Fully offline. Nothing leaves your Mac unless you turn on encrypted backup.
>
> **Memory.** Turn on memory and BurnBar extracts durable facts using your own local model, at zero marginal cost — transcripts pinned to loopback, never egressed. Every candidate waits in a review inbox until you approve it.
>
> **The inbox.** Turn it on and it catches work an agent said was done but never landed, changes you walked away from mid-edit, and PRs that stopped moving — each with exactly one next move. Every model-written claim faces a second model on a different provider whose only job is to refute it; refuted claims are never shown. About $0.016 on an active tick, capped at $1.50/day, and nothing at all on the majority of wakes. Priority items reach your phone even when the Mac is asleep — and the push provider never learns what they say, because the body is encrypted and the function has no key.

---

## 7. Ship order

**Tier 0 — the loop closes (nothing else matters until these land)**

1. Route MCP's direct-SQLite tools through the daemon socket — the path `server.py:3166` already names — or add a keyed connect. Add one encrypted-DB fixture so CI can never be blind to this again.
2. Point memory extraction at `conversations`, not `chat_messages`. Needs session-end debouncing and a batch cost model.
3. Swap the default embedder to `NLEmbeddingProvider`; re-embed. One enum case.
4. One-click MCP install from the Mac app, reusing the gateway's existing config writers. Split the 68-tool server — `openburnbar-memory` (~13 tools) and `openburnbar-ops` — the standing context cost is **10,982 tokens per turn** and 73% is unrelated to memory.
5. **Dogfood it.** Put `openburnbar` in this repo's `.mcp.json` and drop the mem0-first directive from `CLAUDE.md`. Today that file wires `mem0-burnbar`, `zenith`, `context7` and **no openburnbar entry** — we rent a competitor because ours can't open our own file. The day that flips is the day the product is real, and until then no external claim should be made.

**Tier 1 — the product wakes up**

6. An activation path through the five switches, written in the imperative, each earned by a number the user just saw.
7. Fix the five first-run bugs from the prior plan (menu bar renders nothing; 45s scan delay; pet window; no `.quota` route; popover one-way door).
8. Background daemon quota refresh so routing decides on fresh numbers (§4.6).
9. Call `violations(in:)` on inbox output. The enforcement subsystem already exists.
10. Rename the inbox's flagship action from "Resume this session."

**Tier 2 — the money is honest**

11. Meter `insightsHostedAnswer` or cap it hard; reconcile the margin dashboard against real unit costs.
12. Pull the Agent Control and relay top-up packs until a client calls their reserve.
13. Build **the receipt** — join transcripts to spend. Acquisition demo, pricing justification, and the one artifact no competitor can produce.

**Do not ship until Tier 0 is done and dogfooded.**
