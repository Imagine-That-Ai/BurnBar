# 05 — Two-Tier Pricing Brief (the ask for GPT Pro)

> **Document 5 of 5.** This is the request. Docs 1–4 gave you the product, the infrastructure, the per-feature cost behavior, and the unit economics. This document (a) states the decision to be made, (b) proposes the recommended two-tier packaging grounded in the cost structure, (c) gives candidate price points with competitive anchoring, (d) lists the open decisions, and (e) defines exactly what you should return.

---

## 1. The decision to make

**Collapse OpenBurnBar's latent multi-SKU ladder into exactly two paid cloud tiers, and price them.**

Today the code/plans contain five overlapping SKUs ($4.99 quota, $9.99 media, $14.99 umbrella, $14.99 computer-use, $24.99 pro-max) and the website publishes only one ($4.99). That is too many, and it is mis-aligned with the real cost structure. The task is **two clean paid cloud tiers** plus the existing **free local tier** (which is $0 and not "priced" — it's the funnel).

You are pricing **two cloud variants**, not the free tier.

---

## 2. Why two tiers, and where the line is (the cost cliff)

Docs 3–4 establish a sharp, natural seam:

```
              CHEAP / FLAT / BOUNDED                |          VARIABLE / LLM + BANDWIDTH
  ────────────────────────────────────────────────┼──────────────────────────────────────────
  Group A  (blended COGS $0.24–$1.00/user/mo)       │  Group B  (COGS $5–$20+/user/mo, tail→caps)
  • Hosted Quota Sync                               │  • Mercury Media / "Floo"  (relay bandwidth)
  • Encrypted Backup + Zero-Knowledge Search        │  • Computer Use / "Agent Control"  (vision LLM ⭐)
  • Hosted Intelligence Brief (tiny capped LLM)     │
  • Hermes / Pi Agent relay                         │
  • Hosted Remote MCP                               │
  • Cross-device usage sync + push                  │
```

Everything in Group A is **>90% margin at any sane price**. Everything in Group B carries **real, concentrated variable cost** (vision tokens dominate). **Tier 1 = Group A. Tier 2 = Group A + Group B.** This is the recommendation; you may challenge it, but it is the cost-correct default.

---

## 3. Recommended packaging

### Free — "OpenBurnBar" (local, $0) — *context, not priced*
Full local product: parse all providers, live cost/token dashboard, quota windows, menu bar, CLI, editor extension, local FTS search, BYOK routed gateway with failover, **self-hosted** quota runner. Works fully offline, no account. **Operator cost: $0.00/user.** Role: viral acquisition + privacy story.

### Tier 1 — "BurnBar Cloud" (recommended public name) — the sync & search tier
Everything in Free, plus all of **Group A**:
- Hosted quota sync to phone (Codex hosted runner; Claude self-hosted upload)
- Cross-device encrypted session-log backup + zero-knowledge cloud search
- Hosted Intelligence Brief (hosted LLM fallback for analytics Q&A)
- Hermes / Pi Agent remote chat relay (drive your Mac's AI from your phone)
- Hosted Remote MCP (connect external agents to your encrypted memory)
- Cross-device usage sync, devices & approvals, push notifications

**Serving cost:** $0.24/mo median, ~$1.00/mo capped tail. **Margin is a non-issue.**

### Tier 2 — "BurnBar Cloud Pro" / "Studio" — the live + agent-control tier
Everything in Tier 1, plus all of **Group B**:
- **Floo (Mercury Media):** Mac↔phone file transfer, screen-share, video, audio over iroh
- **Agent Control (Computer Use):** supervised autonomous agent control of Mac + sandboxed browser, with cryptographic + Bitcoin-notarized audit trails, four instant-kill paths
- Higher allowances across all Tier-1 features

**Serving cost:** $5.55/mo median, ~$20/mo power, tail bounded by per-user caps ($5/day CU, 5 GB/day media) and global kill-switches. **This is the tier whose price must clear variable cost.**

---

## 4. Mapping to the SKUs that already exist (minimal engineering)

| Recommended tier | Reuse existing entitlement | Existing product id | Already coded? |
|---|---|---|---|
| Tier 1 | `burnbar_pro` (umbrella; also accepts `hosted_quota_sync`) | `com.openburnbar.pro.monthly` | ✅ gates Group A today |
| Tier 2 | `burnbar_pro_max` | `com.openburnbar.proMax.monthly` | ✅ in StoreKit fixture; gates add media + computer-use |

So the two-tier model is **already 90% wired** — `burnbar_pro` unlocks Group A and `burnbar_pro_max` unlocks everything. The remaining work is product/pricing, not plumbing: pick the two prices, set Tier-2 allowances, retire the in-between SKUs ($9.99 media-only, separate $14.99 computer-use) into the two tiers, and publish.

---

## 5. Competitive anchoring (from Doc 1 §7)

| Reference | Price | Relationship to OpenBurnBar |
|---|---|---|
| Raycast Pro | $8 ($8 annual / $10 monthly) | **Closest analog** — a productivity-layer subscription, BYO-AI |
| Raycast Pro + Advanced AI | $16 | Layer + frontier models |
| GitHub Copilot Pro | $10 | Model subscription (not analog; complementary) |
| Cursor Pro / Claude Pro / ChatGPT Plus | $20 | The "frontier model" bucket; OpenBurnBar rides *on top* of these |
| Cursor Pro+ / Claude Max | $60 / $100 | Power-user model spend |

**Framing:** OpenBurnBar is a **companion to** the $20 agents, not a substitute. The honest reference frame is **Raycast ($8–$16)** for Tier 1 and a **capability-priced premium** for Tier 2 (no direct comparable for "drive + audit your Mac coding agent from your phone").

---

## 6. Candidate price points (with rationale — for you to confirm or revise)

### Tier 1 candidates
| Price | Net (Apple 15%) | Margin @ median COGS $0.24 | Rationale |
|---|---|---|---|
| **$4.99** | $4.24 | 94% | Matches today's public price; lowest friction; under-monetizes a rich bundle |
| **$6.99** | $5.94 | 96% | Raycast-band; reflects that T1 is now a *bundle*, not just quota sync |
| **$7.99** ⭐ | $6.79 | 96% | Recommended: clearly above the old $4.99 quota-only price, still impulse-buy; strong anchor below Tier 2 |
| $9.99 | $8.49 | 97% | Aggressive for a BYOK layer; risks feeling like a "$20 tool" without selling tokens |

### Tier 2 candidates (must clear ~$5.55 median / ~$20 power COGS)
| Price | Net (Apple 15%) | Margin @ median $5.55 | Margin @ power $20.80 | Rationale |
|---|---|---|---|---|
| $14.99 | $12.74 | 56% | **−63% (loss on power users)** | Too low unless Tier-2 caps are tightened/allowance-gated |
| **$19.99** ⭐ | $16.99 | 67% | −22% on uncapped power; safe with allowance | Recommended *if* paired with a vision-action allowance + overage |
| **$24.99** | $21.24 | 74% | +2% | Matches existing `pro_max` SKU; safer on power users; "prosumer" price |
| $29.99 | $25.49 | 78% | +18% | Capability-priced; defensible given no direct comparable |

**Strong recommendation:** **Tier 1 = $7.99/mo, Tier 2 = $24.99/mo** (or $19.99 + allowance), with **annual prepay at ~2 months free** ($79 / $249). This (a) lifts Tier 1 above the legacy $4.99 anchor without leaving the impulse band, (b) prices Tier 2 to clear the median+power vision COGS, and (c) preserves the existing `pro`/`pro_max` SKU ids.

---

## 7. Open decisions you must resolve (the actual deliverable)

For each, Doc 3/4 gives the cost facts; you supply the judgment.

1. **Exact monthly price for Tier 1 and Tier 2.** (Anchors in §6.)
2. **Annual pricing / discount.** Recommend ~2 months free; confirm the exact annual numbers.
3. **Tier-2 cost containment model — pick one or a blend:**
   - (a) **High flat price** that absorbs typical vision spend (simplest UX).
   - (b) **Allowance + overage** — e.g. "N agent actions + M GB relay included, then $X/100 actions, $0.10/GB." (The earlier draft proposed $0.10/GB over 5 GB and $0.02/Playwright-step — note that **action overage must cover the ~$0.013 vision cost**, so ≥$0.02/action.)
   - (c) **Tighter Tier-2 per-user caps** (e.g. $2/day vision instead of $5) to bound the tail at the chosen flat price.
4. **Free-tier limits.** Today Free is generous and fully local ($0 cost). Decide whether any cloud teaser (e.g. N free quota refreshes, trial of search) is worth the small COGS to drive conversion. Recommend keeping Free purely local + a **14-day Tier-1 trial**.
5. **Trial design.** Free trial length and which tier it trials. (No trial exists today.)
6. **Channel strategy.** Push Tier-2 / annual to **Stripe web** (higher margin) vs App Store. Decide default.
7. **Tier-2 default vision model.** Sonnet 4.5 ($0.013/action) vs a cheaper model tier inside Agent Control — the single biggest COGS lever (Doc 4 §7).
8. **What happens to the orphan SKUs** ($9.99 media-only, standalone $14.99 computer-use). Recommend folding into the two tiers and grandfathering existing `hosted_quota_sync` $4.99 subscribers into Tier 1.
9. **Teams/Enterprise (future).** Out of scope for "two cloud tiers" but note the upside: seat-based ($19.99/user) with shared audit/notarization is a clean later add-on.

---

## 8. Hard constraints (do not violate)

- **Operator must stay margin-safe on the engaged user, not just the average.** A flat Tier-2 price below ~$15 without allowance/cap tightening loses money on median Computer-Use users (Doc 4 §4.2).
- **The per-user caps and global kill-switches are non-negotiable safety floors** — pricing may assume they remain active ($5/day CU, 5 GB/day media, $1500/$2500 and $600/$1000 global). They bound the operator's total exposure to **<~$4k/mo even at thousands of users**.
- **Apple take is 15% (Small Business) until $1M/yr, then 30%** — model both; web/Stripe is ~6–8%.
- **Tier 1 must remain a clear, cheap, high-margin impulse buy** — it's the conversion step from Free.
- **Public copy uses benefit-first names** (Floo, Agent Control, "Cloud", "Cloud Pro") — never expose transport/codec/codename jargon (Doc 1 §9). Pricing pages must follow the existing benefit-first, safety-forward policy.

---

## 9. What to return (structured output)

Produce a pricing recommendation containing:

1. **Final two-tier table** — names, monthly + annual price, one-line value prop, full feature list per tier, and the per-tier serving-cost & gross-margin (median + power) using Doc 4's numbers.
2. **Tier-2 cost-containment design** — the chosen model from §7.3, with the exact allowance/overage/cap numbers and the margin math proving the engaged user is profitable.
3. **Free-tier + trial definition.**
4. **Channel + SKU plan** — which existing product ids map to which tier, what to do with the orphan SKUs, grandfathering of $4.99 subscribers.
5. **A 3-tier sensitivity check** — show margins at your chosen prices for median / power / capped-tail users, confirming none breach the §8 constraints.
6. **A short go-to-market note** — positioning vs Raycast/Cursor/Copilot (companion, not substitute), the upsell triggers from Free→T1→T2, and the recommended launch sequence.

---

## 10. Quick-reference fact sheet (everything in one place)

| Fact | Value |
|---|---|
| Cloud functions / always-on | 76 / **0 minInstances** |
| Server-funded LLM calls | 2 (insights MiniMax 2.7; daily benchmark) + Computer-Use vision (client-side, metered) |
| Fixed infra floor | ~$220–$250/mo (n0 relay $200 + Secret Manager/Firestore floor) |
| Break-even subs | ~59 @ $4.99 · ~20 @ $14.99 · ~12 @ $24.99 |
| **Tier 1 COGS** | $0.24/mo median · ~$1.00 capped tail |
| **Tier 2 COGS** | $5.55/mo median · ~$20.80 power · ≤~$150 per-user cap (bounded) |
| Quota refresh cap | 30/day, 300/mo → $0.033/user max |
| Computer Use vision | Claude Sonnet 4.5 ~$0.013/action; $5/user/day; global $1500/$2500 kill-switch |
| Media relay | iroh P2P (≥75%); n0 flat $200/mo; 5 GB/day/user; global $600/$1000 kill-switch |
| Apple take | 15% (≤$1M) / 30% (>$1M); Stripe ~6–8% |
| Existing SKUs | quota $4.99 (public), media $9.99, pro $14.99, computer-use $14.99, pro-max $24.99 |
| Recommended | **T1 $7.99/mo ($79/yr) · T2 $24.99/mo ($249/yr)**, T2 with vision allowance+overage |
| Competitive frame | Raycast $8–$16 (analog); Cursor/Claude/ChatGPT $20 (complementary, model subs) |

---

*End of package. Docs 1–4 are the evidence; this document is the question. Return the structured recommendation in §9.*
