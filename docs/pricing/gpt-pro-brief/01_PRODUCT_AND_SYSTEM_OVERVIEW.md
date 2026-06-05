# 01 — Product & System Overview

> **This is document 1 of a 6-part briefing package written for GPT Pro.**
> The mission of the package: give GPT Pro **everything** it needs to price the **two paid cloud tiers** of OpenBurnBar — and (doc 6) execute the launch. Read them in order.
>
> | # | File | What it answers |
> |---|------|-----------------|
> | 1 | `01_PRODUCT_AND_SYSTEM_OVERVIEW.md` | *What are we selling, to whom, and how does it sit vs. the market?* |
> | 2 | `02_CLOUD_BACKEND_AND_INFRASTRUCTURE.md` | *What infrastructure exists and what literally costs money?* |
> | 3 | `03_FEATURE_COST_AND_QUOTA_MAP.md` | *Per-feature: what it consumes, how it's capped, which tier it belongs in.* |
> | 4 | `04_UNIT_ECONOMICS_AND_COGS.md` | *The numbers: per-op cost, per-user COGS, break-even, sensitivity.* |
> | 5 | `05_TWO_TIER_PRICING_BRIEF_FOR_GPT_PRO.md` | *The actual ask: design + price the two cloud tiers.* |
> | 6 | `06_OPERATIONAL_EXECUTION_APPENDIX.md` | *The execution layer: real launch state, exact commands/SKUs/config, the gap to ship two tiers, the launch gate & DoD.* |
> | + | `00_LAUNCH_PROMPT_FOR_GPT5.5_PRO.md` | *The prompt that turns this package into an agent-executable launch plan.* |
>
> **All figures are extracted from the live codebase, plans, and runbooks as of 2026-05-30.** Where a number is a code constant, the file is cited. Where a number is a modeling assumption, it is labeled as such. This package supersedes the earlier thin draft in `docs/pricing/1..5_*.md` and re-frames the question explicitly around **two** cloud tiers.

---

## 1. The one-liner

**OpenBurnBar is a native, local-first macOS menu-bar app that watches your AI coding agents — telling you in real time how many tokens and dollars each one is burning — plus an optional, opt-in cloud that syncs that intelligence (and a set of premium remote-control / search / agent features) across your Mac, iPhone, iPad, and Android.**

- **Bundle id:** `com.openburnbar.app` (the source folder is still named `AgentLens/` for historical reasons; the product is OpenBurnBar).
- **License:** AGPL-3.0-only (open-source core); historical MIT snapshots remain preserved separately.
- **Repo:** `github.com/Imagine-That-Ai/BurnBar`.
- **Status (2026-05-30):** macOS `1.0` submitted to Mac App Store review + shipping as a notarized Developer ID DMG; iOS `1.0` and the first paid subscription ("Hosted Quota Sync") in Apple review with manual release; Android at feature parity.

The product's emotional hook is **cost anxiety**: developers run three or four AI agents in parallel tabs and only discover the bill at month-end. OpenBurnBar sits in the menu bar, reads the session logs those agents already drop on disk, and turns "where did my money go?" into a live, glanceable answer.

---

## 2. Who it is for (ICP)

| Segment | Why they pay | Cloud value that converts them |
|---|---|---|
| **Multi-agent power developers** | Run Claude Code + Codex + Factory/Droid + Cursor simultaneously; spend $100–$400/mo on model subscriptions and API. | Cross-device cost visibility; remote quota refresh from phone; cross-device search of their own agent history. |
| **Mobile-first checkers** | Want to glance at burn/quota from their iPhone without leaving the Mac running. | Hosted quota sync; push notifications; remote agent control ("drive my Mac agent from my phone"). |
| **Privacy-sensitive / regulated** | Code and transcripts must never hit a third-party server in plaintext. | Zero-knowledge (E2E-encrypted) cloud backup + search; Bitcoin-notarized audit trails for agent actions. |
| **Agent operators / "vibe coders"** | Treat agents as semi-autonomous coworkers; want to supervise and steer them remotely. | Remote MCP (connect any agent to their hosted memory), Mercury media (screen-share Mac↔phone), Computer Use / "Agent Control". |

**Critical positioning fact for pricing:** OpenBurnBar is a **companion / meter / sync layer**, *not* a model subscription. It does **not** resell tokens (the user brings their own keys, "BYOK"). It is therefore **complementary** to — not competitive with — Cursor Pro, Claude Pro, ChatGPT Plus, Copilot, etc. This matters enormously for willingness-to-pay (see §7 and Doc 5): the customer is already paying $20–$200/mo for the agents; OpenBurnBar is the meter and remote control *on top* of that spend.

---

## 3. Architecture stance: local-first, cloud-optional

OpenBurnBar is explicitly **daemon-first** and **local-first**. The cloud is an *optional replication and collaboration plane*, never the source of truth.

```
Local SQLite (GRDB, optional SQLCipher at-rest)  ← canonical source of truth
        │
        ├── Firestore under users/{uid}/ ........ optional replication / collaboration plane
        └── iCloud Drive mirror .................. optional file-copy plane (user's own Apple storage)
```

- **Default experience is 100% offline.** No account, no API keys uploaded, no cloud. Analytics are parsed from local log files and stored in local SQLite.
- **Cloud is fully opt-in.** Sign in with Google or Apple (Firebase Auth) to turn on sync. Turn it off and local history keeps working.
- **This is the single most important COGS fact:** a free user costs the operator **$0.00/month** because there is no cloud footprint at all (Doc 4 §1). Cloud cost only begins when a user opts into a paid cloud tier.

---

## 4. Product surfaces (everything that ships)

### 4.1 macOS app (`AgentLens/`)
SwiftUI menu-bar app (`LSUIElement` — no Dock icon, no window stealing focus). Renders the dashboard, settings, parsers, GRDB store, routing UI, and the local gateway controls. **Runs without the macOS App Sandbox** in the Developer ID build (it must read `~/.claude/`, `~/.factory/`, `~/.codex/`, etc., which a sandbox forbids); the Mac App Store build is sandboxed.

### 4.2 Local daemon (`OpenBurnBarDaemon/`)
A `launchd`-managed background helper. The **local control plane**: versioned JSON-RPC over a Unix domain socket, multi-client lease arbitration, quota monitoring, fallback/failover routing, and the **local OpenAI/Anthropic-compatible gateway at `127.0.0.1:8317`**.

### 4.3 `OpenBurnBarCore/`
Shared Swift package (model catalog schemas, tool definitions, approval contracts, run-state machine) used by app, daemon, and tests.

### 4.4 Cursor / VS Code extension (`extensions/openburnbar/`)
Local-first, daemon-backed editor sidebar: Health, Runs, Run Detail, reconnect/repair, workspace-trust-aware tool gating (`read_file`/`search_workspace` always; `apply_patch`/`run_terminal` gated). Source-only today (no Marketplace/VSIX listing yet).

### 4.5 OpenBurnBar CLI (`OpenBurnBarCLI`)
Local control-plane CLI: `health`, `controller`, `questions`, `followups`, `missions`, `mission-approve`, `simulator-runs`, `simulator-replay`.

### 4.6 iOS / iPadOS app (`OpenBurnBarMobile/`)
SwiftUI iOS 17+ companion. Mirrors Mac-published summaries and provider accounts; can add cloud-refreshable provider accounts directly; Quota Watch, Activity ledger, Devices & Sync, encrypted credential transfer. Also the surface for the premium remote features (screen-share, agent control, remote MCP management).

### 4.7 Android app (`android/`)
Native Kotlin, ~100% feature parity with iOS (iroh loopback transport, Tink crypto, BiometricPrompt).

### 4.8 MCP tooling (`tools/openburnbar-mcp/`, `tools/openburnbar-mcp-remote/`)
- **Local MCP helper** — local SQLite MCP server + "BurnBar Resume" + opt-in hosted encrypted semantic search.
- **Hosted Remote MCP stdio shim** (`openburnbar-mcp-remote`) — the **BurnBar Pro** bridge that lets any MCP client connect to the hosted endpoint `https://mcp.burnbar.ai/mcp` with device-side decryption.

### 4.9 Routed-provider gateway
The daemon can wire supported models into Cursor, Factory/Droid, Forge, OpenCode, Codex CLI, and Claude Code through the local OpenAI-compatible gateway (keys stay in Keychain). Cursor gets a Cloudflare quick-tunnel because it blocks `localhost` BYOK targets. v1 upstream scope: Z.ai, MiniMax, Ollama Cloud, OpenAI, Kimi, Anthropic, Factory Droid.

---

## 5. Provider coverage (what it can meter)

| Provider | Usage tracking | Quota reporting |
|---|---|---|
| **Claude Code** | Exact (`~/.claude/projects/*.jsonl`) | Statusline bridge (5h / 7d %); remote refresh self-hosted only |
| **Factory (Droid)** | Exact (`~/.factory/sessions/*.jsonl`) | Estimated (plan tier + tracked monthly tokens) |
| **Codex (OpenAI)** | Estimated (`~/.codex/state_5.sqlite` + rollout JSONL) | Supported; **hosted or self-hosted** remote refresh |
| **Kimi (Moonshot)** | Estimated (`~/.kimi/sessions/*.jsonl`) | Unavailable |
| **Z.ai** | Estimated (via Factory sessions) | Official monitor endpoints |
| **MiniMax** | Estimated (via Factory sessions) | Token-plan remains endpoint |
| **Cursor connector** | Exact (optional, BYOK + local router) | Unavailable |
| Copilot, Aider | Planned | — |

Costs everywhere are computed from **public price tables**, not the user's invoice — "good for trends, bad for tax audits." This is intentional: the operator never needs the user's billing data, which keeps the compliance surface tiny.

---

## 6. The free → paid boundary (what cloud unlocks)

The **free local tier** is the funnel. The **paid cloud** is gated server-side by entitlements in Firestore (`users/{uid}/entitlements/*`), written only by the StoreKit/Stripe/Play verification pipelines — clients can never self-grant.

Cloud value, grouped by cost behavior (this grouping is the spine of the two-tier recommendation in Doc 5):

**Group A — cheap, near-zero-marginal-cost hosted features** (metadata, encrypted blobs, relays the user's own model traffic, no server-side LLM except a tiny capped fallback):
- **Hosted Quota Sync** — refresh Codex/Claude quota to your phone without keeping the Mac awake.
- **Encrypted session-log backup + Zero-Knowledge Cloud Search** — E2E-encrypted transcripts in Cloud Storage; search by opaque hashes across all devices.
- **Hosted Intelligence Brief** — when you have no model configured, a small capped hosted LLM answers analytics questions (the *only* server-funded model call, and it's tightly bounded).
- **Hermes / Pi Agent relay** — pair phone↔Mac AI chat through an encrypted Firestore/iroh relay (relays *your* model, server runs no inference).
- **Hosted Remote MCP** — connect external agents to your encrypted hosted memory.

**Group B — expensive, variable-cost hosted features** (real bandwidth and real server-funded vision tokens):
- **Mercury Media** (public name **"Floo"**) — Mac↔phone file transfer, screen-share, and video over the iroh QUIC mesh, with a hosted relay fallback.
- **Computer Use** (public name **"Agent Control"**) — autonomous/assisted agent control of the Mac and a sandboxed browser, driven by a **server-funded vision LLM**, with cryptographic + Bitcoin-notarized audit trails.

The cost cliff between Group A and Group B is the natural seam for two tiers. Doc 4 quantifies it; Doc 5 packages it.

---

## 7. Competitive & market context (for willingness-to-pay)

The AI developer-subscription market converged hard at **$20/month** in 2026:

| Product | Monthly | Notes |
|---|---|---|
| GitHub Copilot Pro | **$10** | Cheapest; Pro+ $39; moving to usage-based billing 2026-06-01 |
| Cursor Pro | **$20** | Pro+ $60, Ultra $200; heavy users really spend $60–$200+ |
| Claude Pro | **$20** | Max $100 / $200 |
| ChatGPT Plus | **$20** | New ChatGPT Pro tier $100 |
| Raycast Pro | **$8** ($8 annual / $10 monthly) | Advanced-AI add-on +$8 → $16 all-in; Teams $12/user |

Two takeaways for OpenBurnBar pricing:

1. **OpenBurnBar is not in that $20 bucket** — it doesn't sell model access. It's closer to **Raycast** (a $8–$16 productivity-layer subscription) than to Cursor/Claude. The reference frame for an *individual* OpenBurnBar cloud tier is **$5–$15**, not $20.
2. **But the premium agent-control / remote-media tier has no direct comparable** — "drive your Mac coding agent from your phone, with notarized audit trails" is a category of one. That tier can anchor higher ($15–$30) because it competes on *capability*, not on a commodity price.

Sources: [NxCode AI pricing 2026](https://www.nxcode.io/resources/news/ai-coding-tools-pricing-comparison-2026), [Tech-Insider Cursor vs Copilot 2026](https://tech-insider.org/cursor-vs-copilot-2026/), [AIViewer AI pricing 2026](https://aiviewer.ai/guides/ai-pricing-comparison-2026/), [Raycast pricing](https://www.raycast.com/pricing).

---

## 8. What is already monetized today (the starting point)

- **Public, shipped price:** **$4.99/month** for **Hosted Quota Sync** (`com.openburnbar.hostedQuotaSync.cloud.monthly`). This is the only price published on `burnbar.ai` today.
- **Payment rails wired (all three):** Apple StoreKit (live, currently Sandbox default — one config flip to Production), Stripe (fully coded; price ID not yet deployed), Google Play (fully coded; needs published app).
- **Apple take rate:** 15% (App Store Small Business Program) → net ARPU on $4.99 ≈ **$4.24**.
- **A latent SKU ladder already exists in code/plans** (Doc 2 §7, Doc 5 §2): `hosted_quota_sync` $4.99, `hosted_media_sync` $9.99, `burnbar_pro` umbrella $14.99, `hosted_computer_use_sync` $14.99, `burnbar_pro_max` $24.99. **The two-tier task is to collapse / re-package this ladder into exactly two clean paid cloud tiers and price them.**

---

## 9. Naming (internal vs public)

For this internal brief we use the engineering codenames; the public website deliberately uses benefit-first names and never exposes transport/codec jargon.

| Internal / code | Public ("burnbar.ai") |
|---|---|
| Mercury Media (iroh file/screen/video) | **Floo** |
| Computer Use (CGEvent/AX/Playwright/phone-control) | **Agent Control** |
| Hermes / Pi Agent relay | "remote assistant" / "chat relay" |
| Hosted Remote MCP | "connect your coding agent" |
| BurnBar Pro / hosted entitlements | "Cloud" / "Pro" |

Doc 5 proposes the final public tier names; pricing should be set against the *capabilities*, not the codenames.

---

## 10. Hand-off to Doc 2

You now know **what** OpenBurnBar is, **who** buys it, **why** the cloud is opt-in, and **where** it sits in the market. Doc 2 inventories the **actual cloud infrastructure** — every Firebase function, every collection, every external paid API — so you can see exactly what bears cost before Doc 4 turns it into dollars.
