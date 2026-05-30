# 04 — Unit Economics & Cost of Goods Sold (COGS)

> **Document 4 of 5.** The numbers. Per-operation unit cost → per-user monthly COGS → **per-tier serving cost** → break-even and sensitivity. Everything traces to a code constant (Doc 2/3) or a labeled assumption.
>
> **One correction up front:** the earlier draft (`docs/pricing/4_*.md`) modeled Computer Use as *Playwright compute only* and explicitly **excluded LLM tokens**. That understates Tier-2 cost by ~300×. This document includes the **server-funded vision-LLM spend** (default Claude Sonnet 4.5, ~$0.013/action), which is the true dominant Tier-2 cost. Treat this doc as authoritative over the older one.

---

## 1. GCP / external price baselines (us-central1, retail)

| Resource | Unit | Cost (USD) |
|---|---|---|
| Cloud Functions v2 invocation | per 1M | $0.20 |
| Cloud Functions/Run vCPU-second | per vCPU-s | $0.00001667 |
| Cloud Functions/Run RAM | per GB-s | $0.00000333 |
| Firestore writes | per 100k | $0.18 |
| Firestore reads | per 100k | $0.06 |
| Firestore deletes | per 100k | $0.02 |
| Cloud Storage (Standard) | per GB-month | $0.02 |
| Cloud Storage egress (internet) | per GB | $0.08 |
| Secret Manager access | per 10k | $0.03 |
| Secret Manager version storage | per version-month | $0.06 |
| APNs / FCM push | per 1M | **$0.00 (free)** |
| n0 iroh-relay bandwidth (internal accounting) | per GB | $0.04 |
| **n0 iroh-relay tier (flat)** | per month | **$200.00** |
| **OpenRouter — MiniMax 2.7 (insights)** | per 1M in / out | **$0.255 / $1.00** |
| **Anthropic — Claude Sonnet 4.5 (computer-use vision)** | per action (≈3.5k in + 0.4k out) | **≈$0.013** |
| Stripe processing | per charge | 2.9% + $0.30 |
| Apple App Store (Small Business Program) | per charge | **15%** |

---

## 2. Per-operation unit costs (the building blocks)

| Operation | Unit cost | Capped at | Source/notes |
|---|---|---|---|
| Hosted quota refresh | **$0.00010998** | 30/day, 300/mo | Secret access + 4.5 s Cloud Run + 1 write |
| Index one ~160 KB session | **$0.0001172** | batch ≤50 docs/800 chunks | 10 chunks → GCS + Firestore writes + validate |
| One cloud search query | **$0.000083** | ≤50 hits | invocation + ~100 reads |
| Insights hosted LLM answer | **$0.0004–$0.0015** | 1400 out-tok, 24 KB in | OpenRouter MiniMax; fallback-only |
| Hermes/Pi relay message | **<$0.00001** | TTL rate-limits | a few small Firestore writes |
| Remote MCP query | **~$0.00002** | per-tool buckets | Firestore reads + Cloud Run time |
| Usage event sync (write amplified) | **~$0.00002** | rollup counters | ~6–10 writes via `onUsageWritten` |
| **Media relay-fallback hour (1080p screen-share)** | **$0.054** | 5 GB/day; global $1000 | 1.35 GB/hr × $0.04 (accounting); **0 if P2P** |
| **Computer Use action (vision)** | **$0.013** | $5/user/day; global $2500 | Claude Sonnet 4.5; ⭐ dominant T2 cost |
| Computer Use Playwright compute / run (8 steps, 90 s) | $0.0042538 | — | *excludes* the vision tokens above |

**Reading this table:** every Group-A op is in the **$0.00001–$0.0015** range. The two Group-B ops are **$0.013–$0.054 each** — 10–1000× more — which is the entire reason for a second tier.

---

## 3. Tier 1 ("Cloud / Sync") — per-user monthly COGS

Tier 1 = hosted quota sync + encrypted backup/search + insights LLM + Hermes/Pi relay + Remote MCP + usage sync. **No media, no computer use.** This is Group A only.

| Profile | Refreshes | Sessions indexed | Searches | Insights answers | Direct variable cost | + blended relay/secret overhead | **Total T1 COGS** | Margin @ $4.99 net ($4.24) |
|---|---|---|---|---|---|---|---|---|
| **10th pct (light)** | 10 | 10 | 5 | 5 | $0.0027 | $0.10 | **~$0.10/mo** | **98%** |
| **50th pct (median)** | 150 | 100 | 50 | 30 | $0.035 | $0.20 | **~$0.24/mo** | **94%** |
| **90th pct (power)** | 300 (cap) | 500 | 200 | 150 | $0.11 | $0.40 | **~$0.51/mo** | **88%** |
| **99th pct (capped abuse)** | 300 (cap) | 2,000 | 1,000 | 500 | $0.40 | $0.60 | **~$1.00/mo** | **76%** |

> Note: the "blended relay/secret overhead" line allocates the flat **$200/mo n0 relay** across the subscriber base. The per-user share **shrinks as you scale** — at 1,000 subs it's $0.20/user; at 5,000 it's $0.04/user. Tier 1 doesn't itself use the relay, but the model conservatively carries a share of fixed infra. **Even at the 99th percentile, Tier 1 COGS stays ~$1/mo.**

**Tier 1 conclusion:** structurally a **>90% gross-margin product at any price ≥ $5.** The metered parts are hard-capped (quota at $0.033/mo), so Tier 1 has essentially **no tail risk**.

---

## 4. Tier 2 ("Cloud Pro / Studio") — incremental COGS on top of Tier 1

Tier 2 = Tier 1 **plus** Mercury Media (Floo) **plus** Computer Use (Agent Control). The incremental cost is **bandwidth + vision tokens**, which is where pricing must be careful.

### 4.1 Media (Floo) incremental cost
Most sessions are P2P (≈0 cost). Relay-fallback cost only:

| Profile | Relay hours/mo | Media COGS |
|---|---|---|
| Light (P2P holds) | 0 | $0.00 |
| Median | 2 | $0.11 |
| Power | 15 | $0.81 |
| Heavy (near 5 GB/day cap, frequent CGNAT) | 50 | $2.70 |

Plus a diluted share of the flat $200 relay (already partly counted in T1 overhead). **Media is not the scary part** — the per-user 5 GB/day cap + global $1,000 kill-switch bound it hard.

### 4.2 Computer Use (Agent Control) incremental cost — ⭐ the real Tier-2 variable
At **$0.013/action** (Claude Sonnet 4.5 vision):

| Profile | Actions/mo | Vision COGS | Notes |
|---|---|---|---|
| Tourist | 50 | **$0.65** | tries it a few times |
| Median T2 user | 400 (≈10 runs × 40) | **$5.20** | ⚠️ exceeds a $4.99 price by itself |
| Power | 1,500 | **$19.50** | a few caps-hitting days |
| At per-user ceiling | 200/day × 30 = 6,000 | **$78** (≈$5/day cap → max ~$150/mo) | the per-user daily $5 ceiling is the backstop |

**This is the single most important pricing fact in the package:** a genuinely engaged Computer-Use user can burn **$5–$20/month in operator-funded vision tokens**, and the per-user *cap* allows up to **~$150/month**. **Tier 2 cannot be priced like Tier 1.** It needs one (or a mix) of:
- a **high flat price** ($20–$30) that absorbs typical vision spend, and/or
- a **monthly action/vision allowance + overage** (e.g. N actions included, then $/action or $/100-actions), and/or
- a **lower per-user daily cap** for Tier 2 (e.g. $2/day) to bound the tail.

### 4.3 Blended Tier 2 COGS (illustrative)
| Profile | T1 base | + Media | + Computer Use vision | **Total T2 COGS** |
|---|---|---|---|---|
| Light | $0.10 | $0.00 | $0.65 | **~$0.75** |
| Median | $0.24 | $0.11 | $5.20 | **~$5.55** |
| Power | $0.51 | $0.81 | $19.50 | **~$20.80** |
| Tail (capped) | $1.00 | $2.70 | up to ~$150 | **bounded by caps + global kill-switch** |

> The wide spread is intentional and is the core of the Tier-2 pricing problem. Unlike Tier 1, **median Tier-2 COGS (~$5.55) is already near a single-digit subscription price**, so Tier 2 must be priced and/or allowance-structured to keep gross margin healthy on the *engaged* user, not just the average.

---

## 5. Distribution-fee-adjusted ARPU

| Channel | Fee | $4.99 nets | $9.99 nets | $14.99 nets | $24.99 nets |
|---|---|---|---|---|---|
| Apple (Small Business ≤$1M, 15%) | 15% | $4.24 | $8.49 | $12.74 | $21.24 |
| Apple (standard 30%, post-$1M) | 30% | $3.49 | $6.99 | $10.49 | $17.49 |
| Stripe (web, 2.9%+$0.30) | ~6–8% | $4.39 | $9.40 | $14.26 | $24.07 |
| Google Play (15% small business) | 15% | $4.24 | $8.49 | $12.74 | $21.24 |

**Implication:** web (Stripe) is the highest-margin channel; steering power users to web checkout meaningfully improves net ARPU, especially on a higher Tier-2 price. Above $1M/yr Apple revenue the take jumps to 30% — model both.

---

## 6. Fixed costs & break-even

**Monthly fixed infrastructure (independent of user count):**
- n0 iroh relay (team-200): **$200**
- Secret Manager base + misc Firestore/Functions floor: **~$20–$50**
- Cloud Run idle (scale-to-zero): **~$0**
- **Total floor ≈ $220–$250/month.**

**Break-even (covering only the fixed floor):**
| Tier price | Net/user | Subs to cover ~$250 floor |
|---|---|---|
| $4.99 | $4.24 | **~59** |
| $9.99 | $8.49 | **~30** |
| $14.99 | $12.74 | **~20** |
| $24.99 | $21.24 | **~12** |

The earlier doc's "**55 subscribers to break even**" figure is confirmed at the $4.99 anchor. **The business is fixed-cost-light and breaks even in the low dozens of subscribers.**

---

## 7. Sensitivity & scenario levers

| Lever | Effect on COGS | Pricing consequence |
|---|---|---|
| **Computer-Use vision model choice** | Sonnet 4.5 $0.013/action → a cheaper/Haiku-class model could be ~3–5× cheaper | Biggest single COGS lever for T2; consider model tiering inside Agent Control |
| **P2P hit-rate** | ≥75% today → relay bytes are the minority | Higher P2P% → media COGS → ~0; invest in holepunching, not bandwidth |
| **Relay tier dilution** | $200 flat / N subs | At >1k subs the relay is noise; below ~50 subs it dominates |
| **Per-user daily caps** | $5/day CU, 5 GB/day media | Lowering T2 caps directly bounds the tail without changing price |
| **Apple 15%→30% at $1M** | −$0.75 on $4.99, −$3.75 on $24.99 | Bake a 30% scenario into any annualized projection |
| **Annual prepay** | reduces churn, improves cashflow | Standard 2 months free (≈17% discount) is market-normal |

---

## 8. The bottom line for pricing

1. **Tier 1 is a near-pure-margin product.** Blended COGS **$0.24/mo** (median), **$1.00/mo** (99th pct, capped). At any price from **$5 to $15**, gross margin is **88–98%**. Tier 1 risk is essentially zero; price it on *value and market position*, not on cost.
2. **Tier 2's cost is real and concentrated in vision tokens.** Median **~$5.55/mo**, power **~$20/mo**, capped tail **up to ~$150/mo** (bounded). Tier 2 must be priced **and/or allowance-gated** so the *engaged* user stays margin-positive — a flat $5 Tier-2 price would lose money on the median Computer-Use user.
3. **The operator is structurally protected.** Global kill-switches cap aggregate variable spend at **~$1,000 media + $2,500 computer-use + $200 relay ≈ <$4k/mo even at thousands of users.** Pricing can be aggressive because catastrophic loss is impossible by construction.
4. **Channel matters:** route heavy/Tier-2 users to Stripe web checkout to dodge the Apple 15–30% take on the higher price.

Doc 5 turns these economics into the actual two-tier packaging, candidate price points, and the specific decisions for GPT Pro to make.
