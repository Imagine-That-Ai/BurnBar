# BurnBar — Product Focus, Positioning & Onboarding Plan

**Date:** 2026-08-16 · **Status:** proposal, awaiting Alberto's call on §9
**Method:** 21-agent sweep — 7 repo-inventory lanes, 5 market-research lanes, 3 independent ranking lenses, 1 judge, 3 design lanes, 2 adversarial critics. 196 features catalogued from source. Every headline claim below was re-verified by hand against the code; §8 lists the places the agents were wrong.

**Companion documents**

| Document | What it is |
|---|---|
| [product-focus/FEATURE_INVENTORY.md](product-focus/FEATURE_INVENTORY.md) | All 196 features, by surface, with maturity + discoverability + verdict |
| [product-focus/ONBOARDING_SPEC.md](product-focus/ONBOARDING_SPEC.md) | Screen-by-screen first-run design with final copy, motion, and a Swift file manifest |
| [product-focus/MONETIZATION_AND_TRIAL_SPEC.md](product-focus/MONETIZATION_AND_TRIAL_SPEC.md) | Free/paid line, trial mechanic, five upgrade moments, conversion math |
| [product-focus/POSITIONING_AND_SURFACE_AREA.md](product-focus/POSITIONING_AND_SURFACE_AREA.md) | Navigation collapse, demotion list, website rewrite, naming table, 30/60/90 |

---

## 1. TL;DR in plain English

BurnBar does 196 things. It should **sell one**.

The one thing: **you run three or four AI coding agents, and none of them will ever show you the other three. BurnBar shows you all of them at once — how much you have left, everywhere — and when one is about to run dry, it moves you onto your other account so you don't get stopped mid-task.**

Three independent analysts, given the same catalogue and told to rank it three different ways, wrote nearly the same sentence. That agreement is the finding.

Four things follow from it:

1. **The cost meter is not the product.** Free tools already do it better than we admit — CodexBar is MIT, 69 providers, ~20k stars, pushed daily; ccusage does ~420k npm downloads a month. Anthropic's own `/usage` now beats us on Claude specifically. "Reads local logs" was positioning in 2024. In 2026 it's table stakes.
2. **The quota headroom is the product**, because it's the one sentence no vendor is allowed to say. Anthropic will never put Codex's meter next to its own. That ground can't be taken.
3. **The action is what makes it worth money.** "You've used 62%" is worth $0 — it ships in `/usage`. "This kept my job running when Claude drained" is worth $8/mo.
4. **We currently ship none of this well.** The menu bar doesn't render the number at all (§3). The first scan is behind a 45-second delay. There is no trial anywhere in the product. The first thing a new user sees is a desktop pet.

The plan: cut the visible surface from 45 destinations to 11, fix five bugs that each take under a day, ship a zero-decision first run, and add the trial that doesn't exist.

**Two questions for you at the end (§9).** Everything else I'd just do.

---

## 2. What the market actually says

Five research lanes. The short version is uncomfortable and worth sitting with.

| Segment | Verdict |
|---|---|
| **Agent cost meters** | **Saturated, and free.** CodexBar (MIT, 69 providers, ~20k★, pushed daily) is the same product. ccusage ~421k downloads/mo. Vendor-native UI closed most of the gap: Anthropic `/usage` now attributes usage to individual skills, subagents, plugins and MCP servers — *deeper than any log parser can reconstruct*. Not a standalone paid product. |
| **LLM observability / FinOps** | **Different buyer, and we're not in it.** Helicone/Portkey/LangSmith/Datadog need a proxy or SDK, so they never see Claude Max or Cursor Pro subscription spend — which is exactly where the $200–2,000/mo sits. Real gap. But "reads local logs" is *not* the moat: ccusage and CodeBurn (9.4k★, ships its own Mac menu bar app) market that exact line for free. |
| **Agent cockpit / mission control** | **A graveyard.** Terragon shut down Jan 2026. Crystal deprecated Feb 2026. Vibe Kanban — 27.8k★, 30k users, 100k PRs — shut down Apr 2026; the stated reason was "the vast majority are free users and we couldn't find a business model." Imbue took Sculptor to MIT rather than to a paid tier, on $220M+ raised. Then the platform vendors ate it: Anthropic Remote Control (Feb), GitHub *Mission Control* (literally that name), Cursor iOS (Jun). |
| **Mobile / remote agent control** | **Commoditized in five months.** Anthropic shipped Remote Control free on every plan 12 days after Omnara's Launch HN. OpenAI put Codex in the ChatGPT mobile app free, against 4M weekly users. Cursor shipped iOS with Live Activities. Happy Coder: 23.4k★, 100k downloads, monetized nothing, maintainer gone. Demand is real; the market is not. |
| **Indie Mac tool pricing / onboarding** | **Crowded on price, wide open on onboarding.** Everyone converged on $8–12/mo. Almost nobody solved the first 60 seconds. Raycast: signup lands at **4:10** — after four minutes of demonstrated value. Deferred permission prompts grant ~28% more often. |

**The one demand signal nobody answered:** on Omnara's own Launch HN, a user asked whether it showed remaining usage, because they hated running out mid-session. The answer was no. Nobody in the cockpit, mobile, proxy, or FinOps categories answers that question. That's the hole.

**And the corpse pile is the sales argument.** Sniffly a year stale. VibeMeter archived by its own author. claude-code-costs dead. Free tools die on the maintenance treadmill of 30-odd undocumented log formats that change without notice. **Paid maintenance of that treadmill is the actual service.** That belongs on the pricing page.

---

## 3. Five things that are broken right now

Each verified by hand. Each is small. Together they're most of why the app feels the way it does.

| # | What | Evidence | Fix size |
|---|---|---|---|
| 1 | **The menu bar never renders the number.** `Label { EmptyView() } icon: {…}` with `.labelStyle(.iconOnly)`. The cost exists only in `.help(balanceTooltip)` — a hover tooltip. The product is named after a number it does not display. | [MenuBarLabel.swift:73–101](../AgentLens/App/MenuBarLabel.swift#L73) | hours |
| 2 | **First scan is 45 seconds late.** `for _ in 0..<30 where !isSignedIn { sleep 1s }` — a sign-in poll that *never* succeeds for a signed-out stranger — then `sleep(15s)`. With the pixel clock enabled the delay is **600 seconds**. | [AgentLensApp+LiveServices.swift:295–305](../AgentLens/App/AgentLensApp+LiveServices.swift#L295) | hours |
| 3 | **First run is a desktop pet.** `PetOnboardingWindowPresenter.openIfNeeded` calls `activate(ignoringOtherApps: true)`, gated only on `!PetFirstRunModel.hasCompleted` with no feature check. A developer who installed a spend tracker is asked to pick a pet and bind a hotkey. | [AgentLensApp+LiveServices.swift:215](../AgentLens/App/AgentLensApp+LiveServices.swift#L215), [PetOnboardingWindowPresenter.swift:13–15](../AgentLens/PetCompanion/Onboarding/PetOnboardingWindowPresenter.swift#L13) | one line |
| 4 | **The alert can't deep-link to quota.** `NavigationCoordinator.DashboardRoute` has no `quota` case, so the pre-limit alert — the core loop — has nowhere to land. | [NavigationCoordinator.swift:34–42](../AgentLens/Services/NavigationCoordinator.swift#L34) | hours |
| 5 | **No trial exists anywhere.** Zero `introductoryOffer` hits across `AgentLens`, `OpenBurnBarMobile`, `OpenBurnBarCore`. No trial callable in `functions/`. StoreKit is wired for *purchase* only — there is no way to give anyone a taste. | verified by grep across the tree | ~1 week |

Two more worth naming: `OrgRollupView` has **exactly one occurrence in the repo — its own declaration** (dead code, and also the future Team tier's main screen). And `linuxCloudReplica.ts` has `assertAuth` + `assertAppCheck` but **no entitlement gate**, which gives the paid tier away.

---

## 4. The product

> **BurnBar is one number in your menu bar — how much you have left across every AI coding agent you pay for — and it moves you onto your other account before the window closes.**

**Ten-second version, for a user to repeat to a friend:**

> "You know how Claude cuts you off mid-task with no warning? BurnBar puts one number in your menu bar — how much you've got left across Claude, Codex, Cursor, all of them at once. It warns you before a window drains and switches you to your other account in one click. Free, no account, and it works the second you install it because it just reads the logs already on your disk."

**Who:** the solo dev running 2–4 agents on paid plans (Claude Max + Codex + Cursor is the modal stack, $100–400/mo) who has been cut off mid-task with no warning. Second, deliberately later: the founding engineer at a 3–20 person shop who owns that line item and has **nothing to buy** between a $7.99 Mac app and Vantage Business at $200/mo.

**The core loop, several times a day, triggered by the OS rather than by remembering to open an app:**

```
glance at menu bar → tightest window across all agents, as % + reset clock
        ↓
   80% pre-limit alert, before you start something expensive
        ↓
   it drains → one click: switch that CLI to your second account
               (or let the local gateway fail over to another key)
        ↓
   keep working
```

Every additional agent you connect makes the single number *more* valuable — because no vendor will ever show you the other three. That's the compounding.

### 4.1 Ranking: where the 196 landed

44 features were scored on four axes by three independent lenses, then reconciled. Full table in [FEATURE_INVENTORY.md](product-focus/FEATURE_INVENTORY.md).

**Core (9)** — live quota refresh · quota vault + reset atlas · account/CLI switching · menu bar readout · pre-limit alerts + digest · phone quota pressure · local usage aggregation · Live Activities · the Cloud tier itself

**Supporting (11)** — router with quota-drain failover · local gateway · one-click client wiring · iOS widgets · billing-API reconciliation · agents & connections · AI Inbox waste detectors · budget rules *(as **warn**, see §7)* · Engine Room · dashboard overview

**Paid upsell (4)** — hosted quota refresh · cloud vault · hybrid search · durable session warehouse

**Power-user only, behind a door (8)** — 177-method daemon RPC · 68-tool local MCP · 14 charts + Chart Studio · CLI · hosted remote MCP · Project Code Memory · agent memory · context pack export

**Cut or hide (12)** — multi-backend chat (12 backends, 4 presentations) · The Wand · Insights canvases · Elder Wand · Projects · Database workspace · Agent Control / Computer Use · Mercury/Floo · Mission Control · Cloud Pro + Ultra + the four top-ups · Control Deck + Settings Copilot + smart displays + pixel clock · **the desktop pet** (scored 1.5, lowest in the catalogue)

### 4.2 Surface area: 45 → 11

Today: 13 nav destinations, **49 Settings panes**, 6 tray sections, 6 layout themes, 14 charts, three parallel navigation systems, and both a Settings *search engine* and a Settings *Copilot* — which together are an admission that nothing can be found.

The website's own section heading is **"Nine surfaces, one daemon."** We are advertising the problem.

After: **4 destinations day one** (Headroom · Spend · Sessions · Settings), 11 total, 5 Settings panes, everything else behind Labs. Detail and file-by-file demotion list in [POSITIONING_AND_SURFACE_AREA.md](product-focus/POSITIONING_AND_SURFACE_AREA.md).

---

## 5. Onboarding

Full spec with copy, motion beats, wireframes and a Swift file manifest: [ONBOARDING_SPEC.md](product-focus/ONBOARDING_SPEC.md). Headlines:

**Zero steps.** No wizard, no 36-provider pill wall, no four-page tour, no permission prompts. The current 7-step `OnboardingWizardView` is deleted. The core function needs *no* permissions — it reads files in the user's own home directory.

**The structural advantage nobody else has:** the data is already on the disk before the app is installed. `detectAvailableProviders()` runs in milliseconds and already knows Claude Code, Codex and Cursor are there. Every competitor has to wait for the user to *create* data. We spend that advantage today on a pet wizard and a 45-second sleep.

**The two-beat reveal.** ← *this is my correction to the draft spec; see §8*

The draft has one screen at T+1.8s showing four vendors at four percentages. **That state is not reachable on a cold install**, and the reason is a deliberate and correct security decision in our own code. So the reveal is two beats:

- **Beat one, T+2s, no permissions, no account:** real token counts, real dollars, every detected agent, sessions scanned. This is true, immediate, and no competitor shows multi-vendor at once.
- **Beat two, minutes later, after the user's next `claude` run:** the percentage lands. `ClaudeQuotaAdapter` already **auto-installs the statusline bridge silently** on first refresh ([ClaudeQuotaAdapter.swift:139–150](../OpenBurnBarCore/Sources/OpenBurnBarQuota/ProviderQuota/ClaudeQuotaAdapter.swift#L139)), so nothing is asked of the user — the hook simply hasn't fired yet.

This is a **better** design than the draft. Beat one is honest and instant. Beat two is a returning delight moment and the natural reason to send the very first notification — *"Claude just told me: you're at 38% of your weekly window, resets in 2h 14m."* That notification is the aha, and it earns the notification permission by arriving with news rather than asking in advance.

Copy rule, non-negotiable: **never say "Welcome to OpenBurnBar."** The user did not install a greeting.

**Permission ladder — nothing before value:**

| When | Ask | Earned by |
|---|---|---|
| T+0 | *nothing* | — |
| T+2s | *nothing* | the number is on screen |
| First time the user taps "Tell me at 80%" | Notifications | they asked to be told |
| Only if a path returns `EPERM` (MAS build) | Folder read, framed in dollars: *"your Codex sessions are in a folder we can't read yet — grant access to include an estimated $X more"* | a named amount of missing money |
| Never in first run | Sign-in, indexing consent, analytics consent, memory consent | each attached later to the feature it belongs to, one at a time |

**Empty state** (no agent logs found) is a designed screen, not a dead end — it names the 30-odd places we looked, offers "Watch for it," and arms a notification for when the first session appears.

**The aha, instrumented:** *user sees a real number for at least one provider within 60 seconds of first launch.* One event. Ship gate on 200+ external installs, not the internal fleet — the internal fleet is guaranteed to pass and guaranteed to be wrong.

**Day-one checklist, four items:** see your spend → connect a second agent → set a threshold → arm the alert. The second-agent step is the one that makes the cross-vendor thesis real, so it's the primary CTA for anyone with exactly one provider.

---

## 6. Money

Full spec: [MONETIZATION_AND_TRIAL_SPEC.md](product-focus/MONETIZATION_AND_TRIAL_SPEC.md).

### 6.1 Tiers: three paid → one, plus Team later

| Tier | Price | Promise |
|---|---|---|
| **BurnBar Local** | **$0** forever, no account, no card | Every agent you run, one number, before the bill — on one Mac, 30 days of history |
| **BurnBar Cloud** | **$7.99/mo · $79/yr** *(unchanged)* | Your history outlives what the vendors delete, and your phone has the number too |
| **BurnBar Team** | **$15/seat/mo**, 3-seat min — *month 6+, not now* | See what every developer is burning across every vendor, by project, before the invoice |

**The free tier ships the gateway, the router, and one-click client wiring.** All three cost us nothing to run and are the capability no free OSS competitor has. Putting a paywall in front of *"point your $200/mo Claude Max at my localhost proxy"* is the fastest way to lose the trust the whole thing rests on.

**Kill Cloud Pro ($24.99) and Cloud Ultra ($59.99).** Ultra's headline entitlement `tenXMemory` exists **only as a catalogue definition** — all four occurrences in the tree are the enum case, its comment, its catalog entry, and an Android comment ([GatedFeature.swift:110](../OpenBurnBarCore/Sources/OpenBurnBarKernel/Membership/GatedFeature.swift#L110)). No surface in any client ever presents it, so nothing in the shipped product has ever asked anyone to buy Ultra. Pro's $24.99 was justified by Floo, Agent Control and The Wand, all of which this plan cuts. Grandfather existing subscribers; stop selling both. Also move **hosted MCP down into Cloud** — `remoteMcp.ts:61` already asserts only the Cloud floor while every client blocks below Pro, so paying subscribers are currently locked out of a surface the backend would happily serve.

$7.99 stays exactly where it is: three independent comps land on the same anchor (Raycast Pro, CleanShot Cloud Pro, Kaleidoscope, all ~$8).

### 6.2 The trial: 14-day, no-card, reverse

Reverse trial beats the alternatives here for one specific reason: **on day 0 it back-fills the user's entire existing history into the encrypted backup.** What they lose at expiry isn't "14 days of stuff" — it's their whole archive going read-only. That makes 14 days hurt like 90.

- **No card.** Card friction on a sub-$10 tool collapses trial starts roughly 5×, and auto-charge is exactly the dark pattern `FEATURE_GATING_SPEC.md` forbids. A card-required "Subscribe now" runs as a parallel secondary CTA.
- **Never offered in first run.** Only at the five earned moments. Offering a trial to someone who hasn't seen their own number yet asks them to trial a thing they don't understand.
- **At expiry:** entitlement `expireAt` passes; every gate closes on its own, no cron. Nothing is deleted. Local data untouched forever. Vault retained 60 days with export always available.
- **One re-grant ever**, server-owned ledger, client-unwritable.

Both channels need it: MAS build → StoreKit introductory offer; direct-download → self-managed grant (the direct build currently hits `productUnavailable` with nothing but a link to `/pricing`, so a Stripe handoff is required either way).

### 6.3 The claim I'm correcting

The draft sells Cloud as *"your windows stay current while your Mac sleeps."* That is **half true, and the half matters.**

Server-side polling works for the API-backed providers — Cursor, Copilot, Factory, Warp, Z.ai, Kimi, OpenAI, DeepSeek, MiniMax, MiMo, xAI, OpenRouter. It **cannot** work for the local-log providers, and that includes the two flagships: Claude Code's percentage comes from a **local CLI statusline hook**, and Codex's from a rollout log on disk. No server can poll a hook on a sleeping Mac.

Honest version: *"For the twelve providers with a usage API, we keep your windows current while your Mac sleeps. For the ones that only speak to your disk — Claude Code, Codex — your Mac does the reading, and we keep the history."*

That still sells. The durable-history half is the stronger half anyway: **Claude Code deletes session data on a 30-day default, and the vendor will never fix that for you.**

### 6.4 What the paywall may not say

Carry `FEATURE_GATING_SPEC.md` §1 forward verbatim; it is already the right standard. Specifically banned: **"stops your spend"** (it warns — see §7), **"zero-knowledge"** for any hosted surface, **"end-to-end encrypted"** for chat (true only for Floo device-to-device), and bare **"free trial"** without the no-card qualifier.

---

## 7. The honesty correction that costs us a feature

Budget enforcement is ranked and marketed as a stop. **It is a warn.**

`BudgetRule.swift:84` short-circuits subscription credentials to `.allow`, and the daemon's `RoutePipeline` contains **no budget check at all** — there is no `BudgetGate` reference anywhere in `OpenBurnBarDaemon/Sources`. So:

- Ship it as **"warn"**, in the **free** tier, which is where warn-only behaviour actually belongs.
- **Remove it from both paid feature lists** until the gate lands in the route pipeline.
- Never print "stops your spend" on the pricing page.
- Landing enforcement in the route pipeline is the highest-value engineering left after the day-one fixes — at which point it becomes a legitimate paid feature and a genuine differentiator against every log-reader in the category.

Putting this limitation on `/product` turns it into a credibility asset. That's the pattern `website/CLAIMS.md` already established, and it's the best thing about this codebase's culture.

---

## 8. Where the agents were wrong

Reported because it matters more than the parts they got right.

1. **"The zero-config cross-vendor percentage is unreachable" — right on substance, wrong on cause and severity.** The investor critic said it needs the user to hand-edit `~/.claude/settings.json`. In fact `ClaudeQuotaAdapter` **auto-installs the bridge silently** on first refresh, and the reason no percentage appears on a cold install is different and deliberate: the default credentials reader is `NoClaudeCredentialsReader`, an explicit security boundary so that BurnBar *never triggers a Keychain prompt for a third party's credentials* ([ClaudeCredentialsReader.swift:10–17](../OpenBurnBarCore/Sources/OpenBurnBarQuota/ProviderQuota/ClaudeCredentialsReader.swift#L10)). Without credentials, `inferredCaps` returns nil and buckets render token counts with `cap: nil`. So it's not a bug and not a hand-edit — it's a correct choice with a timing consequence. Hence the two-beat reveal in §5.
2. **"Deliverable 4 was not produced" — false, and my fault.** The completeness critic was never handed the onboarding or monetization specs (my workflow script passed it only the positioning spec). Both exist, at 45k and 39k characters, with screen-by-screen copy and a full trial state machine. Its *other* findings stand and are folded into §10.
3. **Provider count drifts across lanes** — 32, 36, 37 depending on whether you count the docs matrix, the ingestion catalog, or registered parsers. `docs/PROVIDERS.md` lists **37 rows**; `contracts/provider-ingestion-catalog.json` has 31 local-parser entries. Pick one number, generate it, and never write it by hand again — the website already does this correctly and the app does not.

Everything else I spot-checked was accurate and unflattering to its own author: the icon-only menu bar label, the 30×1s signed-out poll, the pet window's unconditional activate, `OrgRollupView`'s single occurrence, the absent `introductoryOffer`, the ungated `linuxCloudReplica.ts`, and the `remoteMcp.ts` tier mismatch. All confirmed.

---

## 9. Two questions

**Q1 — Do we kill Cloud Pro and Ultra, or park them?** Killing means grandfathering existing subscribers forever across three billing rails (Apple, Play, Stripe) and eating the migration/support cost. Parking means leaving two SKUs on the pricing page that the product no longer justifies. I recommend **kill, with a dated sunset rather than "forever"** — but it's a revenue call with real subscribers behind it, so it's yours.

**Q2 — Does the desktop pet survive at all?** It scored 1.5, dead last, and it force-activates the app on first launch. I'd delete it from first run today regardless (that's one line and unambiguously right). The question is whether it stays in the product behind Labs, or goes entirely. It's the only feature in the catalogue that's pure delight with no job, and those are sometimes worth keeping — but not in front of a stranger.

---

## 10. Sequencing

### Days 0–30 — "the app says one thing"

Ship-blocking:

1. Render the number in the menu bar (`MenuBarLabel`) — **fix #1**
2. Hoist the scan; delete the signed-out poll and the 15s/600s sleep — **fix #2**
3. Gate the pet window out of first run — **fix #3**, one line
4. Add `.quota` to `DashboardRoute` so the alert can land — **fix #4**
5. Fix the popover's one-way door (`totalUsageSessionCount == 0` permanently hides onboarding once the scan finds anything; its fallback passes a nil aggregator and hangs on "Scanning…")
6. Ship the two-beat reveal and delete `OnboardingWizardView`
7. Collapse to 4 destinations; move the rest behind Labs
8. Close the `linuxCloudReplica.ts` entitlement hole
9. Generate the provider count from one source

Not blocking: 49→5 Settings panes, 6 layout themes → 1, 14 charts → 3, delete the Control Deck and Settings Copilot, delete the verified-dead trees (`gateway/`, `hermes_cli/`, `tui_gateway/` — 0 tracked files each) and the Homebrew cask pinned to 1.0.3 with an all-zero sha256.

### Days 31–60 — "the story matches the app"

Rewrite `/`, `/product`, `/pricing` (drop "Nine surfaces, one daemon"). Flip `pricing.astro` and `CLAIMS.md` in one commit, per existing discipline. Publish the naming table and add a CI grep for the 13 codenames — *Hermes, Mercury, Floo, Elder Wand, Pensieve, AgentLens, Smart Hub…* — none of which a user should ever see. Ship the trial (server ledger + StoreKit offer + Stripe handoff). Kill Pro/Ultra per Q1. Move hosted MCP down to Cloud. Land budget enforcement in the route pipeline.

### Days 61–90 — "the moat, and the second buyer"

Quota-drain failover in the router — the action layer, the thing free tools structurally cannot follow. Mac↔iPhone pairing and the Live Activity (currently no flow by which a Mac user learns the iPhone app exists). Then Team, on the resurrected `OrgRollupView`.

### Before pricing rests on it — carried from the critics, and real

- **ToS review of the credential-extraction quota adapters** (Cursor cookie from `state.vscdb`, Warp GraphQL, Z.ai monitor, Kimi BillingService). Classify all 37 providers as documented-API / undocumented-read-only / credential-extraction, publish the split in `docs/PROVIDERS.md`, and degrade the UI gracefully per class. A paid product should not rest its #1 feature on credential extraction from a competitor's local database without a written read on it.
- **AGPL vs. a paid cloud tier.** Root `LICENSE` is AGPL-3.0-only and this was never addressed. Decide which trees stay AGPL and which are proprietary (`functions/`, `quota-runner/`, `services/` can be), then say it on `/trust` where it's a credibility asset.
- **Inventory the backend.** `functions/` (559 files, ~60 callables) and `quota-runner/` — the containerized implementation of the #1 ranked feature and the stated reason the $7.99 is honest — were never opened. Cost them per subscriber and define their failure mode in the UI.
- **Unit economics.** `tierCogs.ts`, `cloudProAllowance*.ts`, `quotaRefreshSweep` all exist and none was read. Gross margin per tier after Apple's 15/30%, break-even subscriber count, marginal cost of a free user.
- **Distribution.** The plan starts at first launch and says nothing about how anyone arrives. Setapp is the single highest-leverage channel at this price and would change the pricing model entirely.
- **Measure sign-in conversion before building the trial server.** The funnel's dominant lever is the least-evidenced number in it. Ship one no-op "Sign in to enable Cloud" button behind the vendor-deletion moment, measure on 500 real installs, then build.
- **A parser-maintenance cost model.** We're calling the 30-format treadmill "the actual service being sold" and have never budgeted an engineer-hour against it.
