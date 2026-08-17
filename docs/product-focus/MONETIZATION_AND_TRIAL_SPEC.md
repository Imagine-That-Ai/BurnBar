> **Status: draft input, not canon.** Produced by the product-focus agent sweep, 2026-08-16. See [../PRODUCT_FOCUS_AND_ONBOARDING_PLAN.md](../PRODUCT_FOCUS_AND_ONBOARDING_PLAN.md) for the corrections applied on top of this draft — in particular the honest scope of the Cloud "while your Mac sleeps" promise.

---

# BurnBar — Monetization & Trial Plan

**Status:** design spec, code-verified against `/Users/albertonunez/Documents/Developer/BurnBar` @ `usage-memory/pr3-stage0-gate`
**Scope:** free tier definition · trial mechanic · 5 paywall moments · tier ladder · implementation reality (App Store + direct-download) · honesty constraints · conversion model

---

## 0. The one-paragraph version

BurnBar Local stays free forever and stays *complete* — the menu-bar number, all 36 providers, alerts, the account switch, the gateway and router. Cloud is $7.99/mo and buys exactly two things with real COGS: **your windows stay current while your Mac sleeps**, and **your history outlives what the vendors delete**. The trial is a **14-day, no-card reverse trial, granted server-side on every channel** — because BurnBar ships both an App Store build and a direct-download build, and a self-managed entitlement grant is the *only* mechanic that behaves identically on both. The paywall never appears in first run; it appears at five moments where the user has just lost something or just reached for something. Cloud Pro and Ultra stop being sold and every existing subscriber is grandfathered forever.

---

## 1. What is free forever

### 1.1 The free tier: **BurnBar Local — $0, no account, no card**

**Promise line (final copy):**

> **Every agent you run. One number. Before the bill.**
> Free forever on one Mac. No account, no card, no telemetry. It works the second you install it, because it reads the logs already on your disk.

Free includes, permanently:

| Included free | Why it must be free |
|---|---|
| Local usage aggregation across all 36 providers (32 parsers) | `ccusage` does this at 421k downloads/month; CodexBar is MIT with 69 providers. Charging here loses the comparison on day one. |
| Live provider quota refresh — all 23 adapters, all 18 providers with a real signal, while the Mac is awake | This *is* the product. A crippled meter is not a meter. |
| The menu-bar number + the quota vault + reset atlas | Where the product physically lives. |
| Cross-vendor pre-limit alerts (80% / 95%) + daily digest, local delivery | The interrupt is the loop. Gating it kills the loop. |
| One-click CLI account switch | The action. "It kept me working" is the whole story. |
| Local gateway (`127.0.0.1:8317`), 5-D router, one-click client wiring for 9 CLIs | Costs BurnBar nothing to run, and no free OSS competitor has it. Paywalling "point your $200/mo Claude Max at my localhost proxy" is the fastest way to lose the trust the product runs on. |
| Local hybrid search, session browser, charts, CLI, local MCP server, daemon | Already shipped, zero marginal cost, all local. |
| Budget rules in **warn** mode | See §6 — it cannot honestly be sold as "stop". |
| Full local history of *usage totals*, forever, never deleted | Non-negotiable. See below. |

### 1.2 The three limits — and the one I am refusing to take

**Limit 1 — one Mac.** Free tracks one machine. Signing a second Mac into the same account is a Cloud feature. Lands exactly at peak demonstrated value (the README's own ICP runs 2–4 agents in parallel and often two machines).

**Limit 2 — 30-day rolling *transcript* window.** Free browses and searches the last 30 days of conversation transcripts. This matches Claude Code's own 30-day cleanup default, so free BurnBar is never *worse* than the vendor.

**Limit 3 — local-only refresh.** Quota polls while the Mac is awake. Server-side polling is Cloud.

**What I am refusing:** capping usage *totals*, dollar history, or the daily rollup ledger. Those stay complete and forever, on free. Two reasons, and both are load-bearing:

1. **Nothing is ever deleted, and today's number never degrades.** A spend tracker that hides your own spend from you is a trust bomb in a product whose entire pitch is honesty. The free tier hides *transcripts* older than 30 days; it stores them, it just doesn't index or render them, and the moment Cloud turns on they all appear. That's the Raycast clipboard-history model, not a hostage.
2. **BurnBar is AGPL and the database is local SQLCipher.** A determined user can read the rows themselves. This is a *soft* gate by construction, and pretending otherwise would be dishonest. It converts because the reader is a paying professional whose time is worth more than a SQL query — not because it's inescapable.

**Why this free tier is loved but leaves a real reason to pay:** the free product answers "how much have I got left, right now, across everything." The paid product answers "…even when I wasn't at my desk, and what did I do six weeks ago." Those are different questions, and the second one only starts hurting after the user has been using the free one for a month. The cost of staying free compounds silently every day.

---

## 2. The trial mechanic

### 2.1 The four candidates, judged

| Mechanic | Fit for BurnBar | Verdict |
|---|---|---|
| **Card-required trial** (14d, auto-converts) | Highest trial→paid rate (~50–60%), but demands a card for a **$7.99** product with no sales motion. Card friction on a sub-$10 dev tool collapses trial starts by roughly 5×, and the auto-charge is precisely the dark pattern the FEATURE_GATING_SPEC forbids ("no urgency timers, no dark patterns"). It also cannot be made identical across App Store and direct-download. | **Reject as primary.** Keep as a secondary CTA (see 2.4). |
| **Freemium caps only** (no trial) | This is already the substrate — it *is* the free tier. But caps alone never let the user *feel* the paid capability; they only let them feel a wall. Nobody buys "quota refresh while your Mac sleeps" from a description. | **Keep as substrate, reject as the mechanic.** |
| **Credits / consumables** | BurnBar's Cloud value is *continuous* (a server polling every 5 minutes, a backup that must stay current), not consumption-shaped. Credits misprice continuity. The four existing $4.99 top-ups are already fully wired end-to-end and reachable only by scrolling — evidence that credits don't self-merchandise here. | **Reject.** Keep top-ups purchasable for grandfathered Cloud Pro/Ultra only. |
| **Reverse trial** (full Cloud N days → auto-downgrade to free) | The user gets the paid capability *before* they've formed the free-tier habit, so the free tier is experienced as a **downgrade**, not a baseline. Critically for BurnBar: on day 0 the trial **back-fills their entire existing history into the encrypted backup**, so what they lose at expiry is not "14 days of stuff" — it's their whole archive going read-only. That makes a 14-day trial hurt like a 90-day one. | **PICK THIS.** |

### 2.2 The pick: **14-day, no-card reverse trial, Cloud tier only, self-managed grant on every channel**

**Length: 14 days.** Not 30. Three reasons:
- The aha (a window reset caught while the Mac was asleep) fires within 3–5 days for the modal user. 30 days adds no new information, just decay.
- The back-fill makes trial length nearly irrelevant to the size of the loss. Day 1 already puts 1,000+ sessions in the vault.
- Trial COGS is ~$0.42/trialer at 14 days (§7). At 30 days it's $0.90 — still cheap, but the deadline stops being felt, and "no deadline" is why 30-day trials underperform 14-day ones.

**What is unlocked:** the full **Cloud** tier — hosted quota refresh, encrypted backup of the full existing history, cloud search across devices, the phone's live copy of the number, cross-device resume, multi-machine, hosted Remote MCP (moved down to Cloud, §4.3). **Not** Cloud Pro or Ultra features — Floo and Agent Control stay locked. Trialing a tier you no longer sell would be absurd.

**When it is offered:** never in first run. The trial CTA appears only at the five earned moments in §3, plus a permanent, quiet entry in Settings → Cloud. Offering a trial to someone who hasn't yet seen their own number is asking them to trial a thing they don't understand.

**What happens at expiry:** the entitlement doc's `expireAt` passes. Every gate — server predicate, Firestore rule, and client tier — closes on its own with no cron job. The Mac silently returns to free. **Nothing is deleted.** The sealed cloud vault is retained for 60 days (export always available via the existing `dataExport` callable), then subject to normal retention. Local data is untouched, forever.

**One re-grant, ever.** One trial per Firebase UID, enforced by a server-owned, client-unwritable ledger doc, plus a hashed-install-identifier ledger to blunt multi-account farming.

### 2.3 Exact copy at every moment

**A. The offer (appears inside the unlock sheet at any of the five moments)**

> **Try BurnBar Cloud free for 14 days**
> No card. No auto-charge. Nothing to cancel.
> When the 14 days are up, BurnBar goes back to the free plan on its own and every local feature keeps working exactly as it does now.
>
> `[ Start 14 days free ]`
> `Subscribe now — $7.99/mo` · `Not now`

**B. Day 0 — confirmation, shown once, in the menu bar popover**

> **Cloud is on until Sunday, August 30.**
> Your Mac can sleep now — we'll keep polling your five-hour and weekly windows while it does.
> Backing up your history: **1,284 sessions**, encrypted on this Mac before any of it leaves.
> `[ See what changed ]`

**C. Day 5 — the proof, and only if it is true**

> While your Mac was asleep, Cloud caught **3 window resets** you'd have missed — Claude weekly at 06:12, Codex 5-hour at 02:40 and 07:40.
> 9 days left on your trial.

*(Suppression rule: if the count is zero, this notification never fires. A fabricated proof point would be worse than silence.)*

**D. Day 12 — the two-day warning, one notification, no badge, no timer**

> **Two days left on Cloud.**
> After Friday, quota refresh goes back to running only while your Mac is awake, cloud search switches off, and your phone stops getting the number.
> Nothing gets deleted. Your backup stays put and comes straight back if you turn Cloud on later.
> `[ Keep Cloud — $7.99/mo ]` · `[ Let it end ]`

**E. Day 14 — expiry. The single most important copy block in the product.**

> **Your Cloud trial ended. BurnBar is back on the free plan.**
>
> **Still on, forever:** the number in your menu bar, every provider, pre-limit alerts, the one-click account switch, the router, and all your local history.
>
> **Paused:** quota refresh while your Mac sleeps · search across devices · your phone's copy of the number · your second machine.
>
> Your backup is safe and untouched — **1,284 sessions, 41 of which Claude has already deleted from your disk.** Turn Cloud back on any time and it's all still there.
>
> `[ Turn Cloud back on — $7.99/mo ]` · `[ Export my backup ]` · `[ Keep using free ]`

*(The "41 of which Claude has already deleted" line renders only when the count is real and > 0 — BurnBar can compute it, because it watched the files disappear.)*

**F. Day 21 — one post-expiry nudge, then silence forever**

> Since your trial ended, your Mac slept through **9 window resets**. Cloud would have caught them.
> `[ Turn Cloud back on ]` · `[ Don't show me this again ]`

After this, BurnBar never proactively mentions Cloud again unless the user touches a Cloud surface. That restraint is the product's brand.

### 2.4 The parallel card-required express lane

Every trial CTA carries a plain secondary link: **"Subscribe now — $7.99/mo"**. No discount, no urgency, no strikethrough. Some buyers know what they want on day one and resent being routed through a trial. This is one line of UI and it is the cheapest conversion in the plan.

If Alberto later wants a true card-required auto-converting trial on the web rail, **it is already a one-line change**: `functions/src/callables/shared/stripe.ts:42` already treats `"trialing"` as an active state, and `functions/src/callables/stripe.ts:308` already builds a `subscription_data` block. Adding `trial_period_days: 14` there ships it. I am deliberately not doing that, because it would make the Apple and direct-download channels behave differently.

---

## 3. The five upgrade moments

Every one is **event-driven**: it fires because the user just lost something or just reached for something. None fires on a schedule, on launch, or on a count. Each fires **at most once ever**, and a dismissal is permanent for that moment.

### Moment 1 — **The sleep gap**
**Trigger:** app returns to foreground after ≥6 hours of system sleep AND the quota history has a hole ≥1 window reset in it.
**Why it's earned:** the user is looking at a literal blank in their own data. This is the exact capability Cloud sells, demonstrated by its absence.

> **Your Mac slept through a reset.**
> Claude's weekly window rolled over at 04:12 while this Mac was asleep, so BurnBar couldn't see it. You're looking at yesterday's number.
> Cloud polls your windows from a server we run, so the number is right when you sit down.
> `[ Try Cloud free for 14 days ]` · `Not now`

### Moment 2 — **The second machine**
**Trigger:** the same account signs in on a second Mac, OR the user taps "Open on iPhone" / installs the phone app while signed in.
**Why it's earned:** they physically attempted the thing the cap covers. There is no way to read this as a nag.

> **Two Macs, two separate numbers.**
> This Mac doesn't know what the other one burned. Cloud joins them into one number and puts the same one on your phone.
> `[ Try Cloud free for 14 days ]` · `Not now`

### Moment 3 — **The horizon**
**Trigger:** a session search or a transcript scroll hits the 30-day boundary with ≥1 match beyond it.
**Why it's earned:** they asked a specific question and the answer exists — it's just past the line. Show the count, never the content.

> **3 more matches, older than 30 days.**
> BurnBar still has them on this Mac. Cloud indexes your whole history so you can search all of it, from any device.
> `[ Try Cloud free for 14 days ]` · `Not now`

### Moment 4 — **The vendor deletion** *(the strongest one in the product)*
**Trigger:** BurnBar's file watcher observes session files it had already indexed disappear from disk — Claude Code's 30-day cleanup doing its job.
**Why it's earned:** something was taken from the user, by someone else, and BurnBar is the only thing in the room that noticed. This is not an upsell, it's a report.

> **Claude just deleted 41 of your sessions.**
> That's its 30-day cleanup, and it will keep happening. BurnBar still has the copies on this Mac — but only this Mac.
> Cloud keeps a sealed backup so the next cleanup, or the next wiped laptop, doesn't take them.
> `[ Try Cloud free for 14 days ]` · `[ Export them myself ]` · `Not now`

### Moment 5 — **The alert you weren't there for**
**Trigger:** a pre-limit or drain alert fires while the display is asleep or the session is locked, and goes unacknowledged for >30 minutes.
**Why it's earned:** the core loop failed in the one way free cannot fix. The alert was correct and useless.

> **You weren't at your desk when Codex hit 95%.**
> The alert fired here at 03:40 and sat on a sleeping screen.
> Cloud pushes it to your phone and puts the window on your lock screen, so the warning reaches you wherever you are.
> `[ Try Cloud free for 14 days ]` · `Not now`

**Global rules for all five:** one soft CTA, one quiet dismiss, no red, no countdown, no "Upgrade required" — header reads "Available on Cloud." Maximum **one** paywall moment per rolling 7 days regardless of how many trigger. All five are suppressed entirely during a trial and for 60 days after a trial ends (the day-21 nudge is the only exception).

---

## 4. Tier structure

### 4.1 The verdict: collapse three paid tiers to one, add Team later

| Today | Decision |
|---|---|
| OpenBurnBar Local — $0 | **KEEP**, unchanged. |
| BurnBar Cloud — $7.99/mo · $79/yr | **KEEP the price exactly.** |
| BurnBar Cloud Pro — $24.99/mo · $249/yr | **STOP SELLING.** Grandfather every subscriber at price and features, forever. |
| BurnBar Ultra — $59.99/mo · $599/yr | **STOP SELLING.** Grandfather forever. |
| 4 consumable top-ups ($4.99 ×3, $19.99) | **Remove from all new-user surfaces.** Keep purchasable for grandfathered Pro/Ultra members who need them. |
| — | **ADD (month 6+): BurnBar Team — $15/seat/mo, $12/seat annual, 3-seat minimum.** |

### 4.2 Why $7.99 stays exactly where it is

Three independent comps sit on the identical anchor: **Raycast Pro $8/mo annual**, **CleanShot Cloud Pro $8/mo annual**, **Kaleidoscope $8/mo**. All three are the same shape — free-or-paid local app, subscription buys the hosted half. That is the only pricing story this market has ever accepted, and every pure-software menu-bar subscription that ignored it died (TokenBar's $5/mo sits next to its own $15 lifetime option). Repricing up loses the comp; repricing down doesn't cover COGS and signals a toy.

### 4.3 Why Cloud Pro and Ultra die

**Ultra has never once been sold.** `tenXMemory` / `TEN_X_MEMORY` has **zero call sites on macOS, iOS and Android**. Nothing in the shipped product has ever asked a human being to buy it. And its own upsell copy (`GatedFeature.swift:319`, `GatedFeature.kt:282`) advertises *15 sources / 50,000 chunks / 250 MB* against enforced server limits of *100 / 500,000 / 10 GiB* (`functions/src/callables/knowledgeMemory.ts:158-161`) — it understates the real product by 10–40×. A tier with no upsell surface and inverted copy is not a tier.

**Cloud Pro's content is exactly what the day-one plan hides.** Its justification was Floo, Agent Control and Wand ×8. All three leave the front of the product. A paid tier whose contents are hidden is not a tier.

**Three paid tiers for an unproven product is one too many.** Pricing-page norms for solo-dev tools are free + one paid + (optionally) team. Every extra rung costs conversion in decision cost and costs the team a copy set, a paywall set, and a grandfathering story.

**One repricing correction to land with the collapse:** move **hosted Remote MCP down to Cloud**. `functions/src/callables/remoteMcp.ts:61` uses `assertActiveBurnBarProEntitlement` — the **Cloud** floor — and `services/hosted-mcp/src/entitlements.ts:74-78` maps `burnbar_pro` to tier `"pro"`. Meanwhile the shared catalog and every client require Cloud Pro. Right now BurnBar blocks paying Cloud subscribers from a surface its own server would happily serve. Fix the client to match the server, not the other way around.

### 4.4 Team, at month 6+

$15/seat/mo, $12/seat annual, 3-seat minimum. Sits inside the $15–40/seat band the research names and well under LangSmith's $39 anchor. It fills the only genuinely empty and genuinely purchasable gap in this market — the 3–20 person shop with nothing between a $7.99 Mac app and Vantage Business at $200/mo. It also resurrects `OrgRollupView.swift`, which is shipped code with zero call sites and a live data layer (`fetchOrgRollup` / `UsageStore+OrgRollup`). And it is the one plane free single-machine OSS structurally cannot follow, because it needs a server. **Ship it after Cloud converts, not on day one.**

### 4.5 The pricing page, final

> **Free where it should be. Paid where it costs us money.**
>
> **OpenBurnBar Local — $0 forever.** No account. No card. One Mac, 30 days of searchable transcripts, everything else unlimited.
> **BurnBar Cloud — $7.99/mo, or $79/year.** Your windows stay current while your Mac sleeps. Your history outlives what the vendors delete. Every Mac, iPhone and iPad you own.
> **Team — from $12/seat.** Coming soon.
>
> Existing Cloud Pro and Ultra subscribers keep their plan, their price and their features for as long as they keep it. Neither is sold as a new plan.

---

## 5. Implementation reality

### 5.1 What already exists (verified in code)

**Billing rails: all three are real and finished.**
- Apple StoreKit 2 buy/restore on iOS (`OpenBurnBarMobile/Models/HostedQuotaSubscriptionStore.swift:417`) and macOS (`AgentLens/Views/Settings/CloudStoreSettingsView+Support.swift:466`).
- Google Play Billing 9.1.0 with `verifyGooglePlayBurnBarProSubscription`, RTDN reconciliation (`functions/src/googlePlayRtdn.ts`), and a daily voided-purchase backstop.
- Stripe Checkout web (`functions/src/callables/stripe.ts`), with a webhook dedupe ledger.

**Verification is genuinely strong.** `functions/src/appstore/verifier.ts` pins three Apple root-CA SHA-256 fingerprints and fails cold start on mismatch. The client mints a server-side `appAccountToken` via `beginEntitlementBinding` *before* `Product.purchase()`, so the server never trusts a client-supplied uid. `users/{uid}/entitlements/*` is client-**read-only** — "entitlements" appears in the read allowlist at `firestore.rules:1878` and in none of the write allowlists.

**Entitlement expiry is already the auto-downgrade mechanism.** `packages/entitlements/src/predicate.ts:evaluateEntitlement` grants a feature iff `active === true` **AND** `productID ∈ the feature's allowlist` **AND** `expireAt > now`. `firestore.rules:422-476` independently re-checks the same three things. **This means a time-boxed grant expires by itself, server-side and rules-side, with no cron job, no client cooperation and no revocation call.** That is the entire trial engine, already built.

**Client tier resolution needs no changes.** `MacCloudEntitlementStore` (`AgentLens/Services/MacCloudEntitlementStore.swift:413`) resolves `cloudTier` from live Firestore listeners on five docs including `hosted_quota_sync`, and `isActive → .cloud` opens every Cloud gate. iOS and Android do the same.

**Stripe already honors trials.** `functions/src/callables/shared/stripe.ts:42` — `STRIPE_ACTIVE_STATES = {"active", "trialing", "past_due"}`.

### 5.2 What does not exist

- **No trial of any kind.** Zero `introductoryOffer` / `freeTrial` / `isEligibleForIntroOffer` hits in any shipped client. The only artifact is `OpenBurnBarMobileTests/Resources/OpenBurnBarPaidTiers.storekit` (a `P2W` free trial on `com.openburnbar.pro.monthly`), attached only to the Xcode LaunchAction — it never reaches a user and creates no App Store Connect offer.
- **No `startTrial` / `grantTrial` callable anywhere.** `functions/src/index.ts` exports 65 functions; none of them grant anything.
- **No purchase path on the direct-download Mac build.** `DISTRIBUTION_MAS` is set only by the MAS build scripts; `CloudStoreSettingsView` has no non-MAS purchase branch, so `Product.products` returns empty and the only fallback is a plain `Link` to `https://burnbar.ai/pricing` at `CloudStoreSettingsView.swift:1472` — not `/subscribe`, not a checkout.
- **Stripe price IDs have no compiled default** (`functions/src/config.ts:358-405`). The web rail is dead until they're provisioned.
- **Linux gets the whole Cloud product free.** `functions/src/callables/linuxCloudReplica.ts` — `pushLinuxCloudReplicas` (:210) and `pullLinuxCloudReplicas` (:283) sync usage, conversations, session_logs, text_expansion and roaming_profile behind `assertAuth` + `assertAppCheck` **only**. Grep for `assertActive` in that file returns **0**.
- **The website actively contradicts the plan.** `website/src/pages/pricing.astro:61-63` — "No introductory offer is promised" — backed by `website/CLAIMS.md:168`. The claims matrix is a build gate; this must change in the same PR.

### 5.3 StoreKit introductory offer vs. self-managed grant — the both-channels answer

BurnBar ships an App Store build **and** a Sparkle direct-download build, plus Play, plus Linux and Windows. Here is the honest matrix:

| Channel | StoreKit/Play intro offer available? | Self-managed grant available? |
|---|---|---|
| iOS / iPadOS App Store | Yes | Yes |
| macOS App Store (`DISTRIBUTION_MAS`) | Yes | Yes |
| macOS direct download (Sparkle) | **No — StoreKit IAP does not exist in this build** | Yes |
| Google Play | Yes (base-plan free-trial offer) | Yes |
| Linux / Windows / web | **No** | Yes |

**Decision: self-managed grant everywhere. Ship no StoreKit or Play introductory offer.**

Rationale:
1. A no-card reverse trial isn't a *sale*, so Apple's IAP requirement does not attach. Giving an entitlement away costs nothing in policy terms; the eventual purchase still goes through StoreKit on Apple channels, which is the only thing Apple actually requires.
2. An intro offer cannot exist on the direct-download build at all. Using intro offers on Apple and grants elsewhere would produce two funnels, two copy sets, two eligibility models (Apple ID family vs Firebase UID), and two support stories, for a $7.99 product.
3. **Double-dip hazard:** if an App Store Connect intro offer *and* a server grant both exist, a user chains them — 14 free days on the grant, then 14 more on the intro offer at purchase. Guard: verify no intro offer is configured in App Store Connect or on the Play base plan, and add a CI assertion that no shipped client renders trial copy sourced from `product.subscription?.introductoryOffer`.
4. What is given up: Apple's "Free trial" merchandising badge on the store listing, and auto-conversion. Auto-conversion is a feature we don't want — it's the dark pattern the gating spec forbids.

### 5.4 The build order — what ships the trial

**Server (the whole trial is ~250 lines):**

1. **`packages/entitlements/src/catalog.ts`** — add a trial product ID (`burnbar.cloud.trial`). Add it to the `hostedQuota` **and** `premium` feature sets and to `FIRESTORE_RULES_PRODUCT_ID_ALLOWLISTS.premium`. **Do not** add it to `proMax`, `ultra`, `media` or `computerUse` — the trial grants Cloud only, so Floo and Agent Control stay correctly locked. Then regenerate rules (`node tools/gen-rules-entitlements.mjs`) and re-pin `packages/entitlements/fixtures/product-id-catalog.json`; the CI drift gate compares bytes.

2. **Write the trial to the `hosted_quota_sync` doc path, not `burnbar_pro`.** This is the highest-leverage detail in the whole implementation:
   - Both `assertActiveBurnBarProEntitlement` (`shared/entitlements.ts:57`) and `firestore.rules:484` already read that path via `isActivePremiumEntitlement` / `activePremiumEntitlementData`.
   - The legacy `$4.99` SKU that used to live there is **honored but no longer sold**, so no new purchase will ever write it.
   - Therefore trial docs and paid docs **never collide**, and `MacCloudEntitlementStore` already listens to it. **The reverse trial ships without touching a single line of client gating code.**

3. **New callable `startCloudTrial`** (`functions/src/callables/cloudTrial.ts`, registered in `functions/src/index.ts`). Guards: `assertAuth` (non-anonymous), `assertAppCheck`, **refuse** if a `hosted_quota_sync` doc already exists (legacy subscriber), **refuse** if any active `burnbar_pro`/`burnbar_pro_max`/`burnbar_ultra`, **refuse** if the one-per-uid ledger `users/{uid}/trial_grants/cloud_v1` exists (server-owned, client-unwritable), **refuse** on a hashed-install-identifier ledger hit. Writes `{ active: true, productID: TRIAL_ID, source: "internal_trial_grant", platform, isTrial: true, expireAt: now + 14d }`. Add a Remote Config kill switch to stop granting new trials.

4. **Extend `sameEntitlementWriteSource`** (`functions/src/callables/shared/entitlementWriteSource.ts`) so any verified provider write supersedes an `internal_trial_grant` doc, mirroring the existing `internal_operator_grant` + Stripe escape hatch. **This is a real hazard, not a formality:** `paidEntitlementWriteWouldDowngrade` (`shared/entitlements.ts:331-348`) returns `true` — i.e. *skips the write* — whenever an active existing doc with a later expiry has a different `source`. Without this fix, a revocation or a short-dated verified write against a live trial is silently dropped.

5. **Close the Linux hole.** Add `assertActiveBurnBarProEntitlement(uid)` at `linuxCloudReplica.ts:210` and `:283`. Otherwise the trial is meaningless on Linux and Cloud is permanently free there.

6. **Provision the Stripe price IDs** (`functions/src/config.ts:358-405`) — the web rail is the *only* purchase path for direct-download Mac, Linux and Windows.

**Client:**

7. **Read `isTrial` / `expireAt` for copy only.** `MacCloudEntitlementDocument` is a dictionary subscript (`MacCloudEntitlementStore.swift:333-343`), and `expirationDate` is already `@Published` — the countdown chip and every §2.3 block are pure presentation over existing state.

8. **Wire the five §3 triggers** into the existing `FeatureUnlockSheet` / `LockedFeatureVeil` machinery; add a `trialCTA` variant to `GatedFeature`. Fix the two pre-spec veils still hardcoding "Open Cloud" (`InsightsRootView.swift:92`, `StreamsView+Cockpit.swift:39`) — they're the highest-traffic locked surfaces in the iOS app.

9. **Fix the direct-download purchase gap.** Replace the bare `Link` at `CloudStoreSettingsView.swift:1472` with a Stripe handoff: a callable mints a short-lived one-time checkout token, the app opens `https://burnbar.ai/subscribe?t=<token>` (**never the uid or email in a query string**), and Stripe returns via a `openburnbar://subscription/complete` deep link. Same handoff unblocks Windows (`WindowsSettingsPersistence.cs:562` currently returns a stub string).

**Evidence & docs:**

10. Update `website/src/pages/pricing.astro:61-63` and `website/CLAIMS.md:168` in the same PR — the claims matrix is a build gate and will fail otherwise.
11. Add two rows to `launch-evidence/cross-channel-paid-path-matrix.json`: `cloud_trial_grant_then_expiry_fail_closed` and `cloud_trial_superseded_by_paid_purchase`.

---

## 6. Honesty constraints on paywall copy

`docs/FEATURE_GATING_SPEC.md` is the binding contract. The definition of done already greps for violations.

### 6.1 The paywall MAY say

- "Encrypted backup." "Sealed on your device before it leaves." "Your history outlives what the vendors delete."
- "Hosted recall searches cloaked structures; plaintext and vault keys stay device-only, while search and access patterns remain visible." (Verbatim from the spec. Say the whole thing or none of it.)
- **"End-to-end encrypted" — for Floo device-to-device only.** That claim is valid there and nowhere else.
- "Your entitlement is verified against Apple, Google or Stripe. The app can never grant itself a subscription." — code-true; `firestore.rules` denies all client writes to `entitlements/*`.
- "Quota refresh runs on a server we pay for, so your windows stay current while your Mac sleeps." — the honest, COGS-backed reason to charge. Say it in those words.
- Provider fidelity, labeled: **exact** for the 24 with a local artifact or official API, **estimated** for Copilot / Cursor cookie / Forge / SuperGrok pacing / the ~24h-lagged Anthropic Admin API, **unavailable** for the 9 install-detection-only providers. `QuotaRefreshActor` already refuses to fabricate a number; the copy must match.
- "No card. No auto-charge. Nothing to cancel."

### 6.2 The paywall MAY NOT say

- **"End-to-end encrypted"** about chat, session backup, cloud search, agent memory or Pensieve. Server-assisted search exists.
- **"We can never see it" / "zero-knowledge" / "the server reads nothing"** for any hosted surface. Two currently-shipped bullets in `GatedFeature.swift` violate this ("never reads your content", "not by exposing a single word of your content") — **fix them before any paywall ships.**
- **"Inversion-proof" or "fully unlinkable"** about the vector cloak.
- **"Computer Use"** in user copy. The public name is **Agent Control**.
- **"Stops / blocks / caps your spend."** `BudgetRule.swift:84` short-circuits subscription credentials to `.allow`, and the daemon's `RoutePipeline` contains no budget check at all. The gate does **not** stop the exact runaway the market fears — a subscription-plan agent burning a window overnight. Ship and sell it as **"warns you before you cross a line you set."** Enforcing the gate in the route pipeline is the highest-value engineering left; until it lands, the pricing page does not mention stopping.
- **The Ultra "10×" bullet as currently written** (15 sources / 50,000 chunks / 250 MB) — it understates the enforced limits by 10–40×. Since Ultra is no longer sold, delete the copy rather than fixing it.
- **"No introductory offer is promised"** — must be updated when the trial ships.
- **"Free trial"** without the qualifier. Because there is no card and no auto-charge, the copy must always be "**14 days free — no card**", never a bare "free trial" that implies the auto-renew convention.
- Any Windows or Linux availability claim on the pricing page. Windows' only release is an unpublished x64 draft; Linux's own ledger reports 0/40 product requirements ready.
- Any urgency device: countdown timers, red badges, "expires soon" interstitials, or a dismissal that doesn't stick.

---

## 7. Expected conversion math

### 7.1 Assumptions — stated, not measured

Every number below is an assumption. None is instrumented today. The single required instrumented event before any of this is trustworthy: **"user sees a real number for at least one provider within 60 seconds of first launch."**

| # | Assumption | Value | Basis |
|---|---|---|---|
| A1 | Activation (real number ≤60s) | **78%** of installs | Data is already on disk; 32 parsers; the residual is unsupported stacks and non-default log paths. Requires the first-run fixes (delete the pet wizard, hoist the scan out of the 45s sign-in poll). |
| A2 | Day-7 retention among activated | **45%** | Menu-bar residency is high-retention; the loop fires several times a day. |
| A3 | Trial start among activated | **22%** | The real friction is a Firebase sign-in, not the trial. Dev-tool account-creation when tied to a concrete benefit runs 15–30%. |
| A4 | Trial → paid (no card) | **11%** | No-card reverse trials land 8–15%. Back-fill makes the loss real; a $7.99 price makes the decision cheap. |
| A5 | Plan mix | 70% monthly / 30% annual | Standard for an $8 anchor with an 18% annual discount. |
| A6 | Monthly logo churn | 5.5% | Utility subscriptions at this price; the free tier remains usable, so churn is real. |
| A7 | Store/processor take | 12% blended | Apple/Google Small Business 15%, Stripe ~3.4% + 30¢, mixed. |
| A8 | COGS per paying member | **$0.90/mo** | Hosted quota polling + Firestore R/W + 250 MB transcripts / 1 GB index (the limits already coded in `CloudSyncTypes.swift:253-255`). |
| A9 | COGS per trialer | **$0.03/day → $0.42 per 14-day trial** | Same infrastructure, no annual storage tail. |

### 7.2 The funnel, per 10,000 installs

```
10,000 installs
  ×78% activation              → 7,800 see a real number
  ×45% day-7 retention         → 3,510 still running at day 7
  ×22% trial start             → 1,716 trials started
  ×11% trial→paid              →   189 paying subscribers
                               = 1.89% install→paid
```

1.89% sits mid-band for dev-tool freemium (1–4%), which is the right place for a plan with no advertising claims behind it.

### 7.3 Unit economics

- **ARPU/mo** = 0.7 × $7.99 + 0.3 × ($79 ÷ 12) = $5.59 + $1.98 = **$7.57**
- **Average lifetime** ≈ 16 months blended (monthly at 5.5% churn, annual at ~28% non-renewal)
- **Gross LTV** ≈ $121 → **net of store take (A7)** ≈ $107 → **net of COGS (A8, ×16mo = $14.40)** ≈ **$92 contribution per subscriber**
- **Trial cost per acquired subscriber** = (1,716 × $0.42) ÷ 189 = **$3.81**
- **Contribution per 10,000 installs** = 189 × $92 − $721 trial COGS ≈ **$16,667**

**The decisive number:** the trial breaks even at a trial→paid rate of $0.42 ÷ $92 = **0.46%**. The assumed rate is 11% — a **24× margin of safety**. That margin is precisely why the card requirement is unnecessary: the card exists to protect against trial abuse, and there is nothing here worth abusing.

### 7.4 The counterfactual — did I pick right?

| Mechanic | Trial starts / 10k installs | → paid | Paid / 10k | vs. pick |
|---|---|---|---|---|
| **Reverse trial, no card (pick)** | 1,716 | 11% | **189** | — |
| Card-required trial, auto-convert | ~316 (card friction ≈5× on a $7.99 product) | 55% | **174** | −8% paid, plus chargebacks, refund support, and a dark pattern the gating spec forbids |
| Freemium only, no trial | n/a | 3.5% of activated buy directly | **123** | −35% |
| Credits / consumables | n/a | mispriced against continuous value | ~60 | −68% |

Honest reading: **card-required is close** — within 10% on paid count. It loses on top-of-funnel volume (a 5× smaller pool of people who have experienced the paid product, which matters enormously for word of mouth in a developer market), on refund and chargeback drag, and on brand — BurnBar's entire differentiator is that it tells the truth about numbers, and an auto-charging trial on a $7.99 tool is the one move that undermines that. That is why the express-lane "Subscribe now" CTA stays: it recovers most of the card lane's advantage at the cost of one line of UI.

### 7.5 Sensitivity

| Scenario | Trial start | Trial→paid | Paid / 10k | Install→paid |
|---|---|---|---|---|
| Pessimistic (sign-in friction bites) | 12% | 8% | 84 | 0.84% |
| **Base** | 22% | 11% | **189** | **1.89%** |
| Optimistic (moments land, first-run fixed) | 30% | 15% | 316 | 3.16% |

The dominant lever is **A3, trial start** — i.e. the sign-in — not A4. Every point of effort should go into making the five moments land and making sign-in feel like a consequence of the moment rather than a toll. A trial gated behind a sign-in gated behind an unearned paywall converts at zero regardless of trial design.

### 7.6 Twelve-month picture

At a steady 2,500 installs/month (macOS direct + MAS), month 12 yields roughly **1,000–1,200 cumulative paying subscribers** after churn ≈ **$7.6–9.1k MRR** from Cloud alone. Team, launched month 6 at $12–15/seat with a 3-seat minimum and even 40 small teams, adds ≈ **$1.8k MRR** — about 20% of revenue from ~3% of accounts, which is the normal and correct shape, and the reason Team is on the roadmap rather than on the day-one pricing page.

---

## 8. Ship order

1. **First-run fixes** (delete pet wizard from launch; hoist the scan; fix the menu-bar label to render the number). Nothing below converts without A1.
2. **Close `linuxCloudReplica.ts`** — stop giving Cloud away.
3. **Fix the two honesty violations** in `GatedFeature.swift` ("never reads your content").
4. **Trial server** — catalog + rules regen + `startCloudTrial` + `sameEntitlementWriteSource`.
5. **Trial client copy** — §2.3 blocks + countdown chip.
6. **The five moments** — §3, one at a time, Moment 4 (vendor deletion) first because it is the strongest and cheapest.
7. **Direct-download Stripe handoff** + provision Stripe price IDs.
8. **Collapse the ladder** — stop selling Pro/Ultra, grandfather, move hosted MCP down to Cloud, update pricing page + CLAIMS.md.
9. **Team**, month 6+.
