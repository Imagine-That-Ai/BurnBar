> **Status: draft input, not canon.** Produced by the product-focus agent sweep, 2026-08-16. See [../PRODUCT_FOCUS_AND_ONBOARDING_PLAN.md](../PRODUCT_FOCUS_AND_ONBOARDING_PLAN.md) for the master plan this feeds.

---

# BurnBar — Positioning & Surface-Area Plan

**The thesis:** BurnBar is *one number in your menu bar — how much you have left across every AI coding agent you pay for — and the one action that keeps you working when it drains.* Everything in this plan is a consequence of that sentence. Every destination, page, and name either serves it or gets demoted.

The current app does not fail because it lacks features. It fails because a user cannot tell what it is. There are **three competing route enums**, **11 dashboard routes**, **11 Control Deck tiles**, **17 Settings panes**, and **6 drag-resizable tray sections** — and the route enum that deep links actually use (`NavigationCoordinator.DashboardRoute`) *cannot even reach Quota*, the single most important screen in the product. That is the whole problem in one line of code.

---

## 1. Top-level navigation: before and after

### 1a. What exists today (verified in source)

There are **three parallel navigation systems** that disagree with each other.

**System A — `DashboardMainRoute`** (`AgentLens/Views/Dashboard/DashboardNavigationModel.swift:5-23`): 11 named routes + `controlDeck` + dynamic `provider(_)` / `model(_)`.

```
overview · insights · charts · database · projects · missions
sessionLogs · memoryReview · inbox · chat · quota · controlDeck
```

`primarySections` (line 30) drives ⌘1–⌘8 and is a *different, smaller* set:

| ⌘ | Route |
|---|---|
| ⌘1 | inbox |
| ⌘2 | chat |
| ⌘3 | quota |
| ⌘4 | database |
| ⌘5 | projects |
| ⌘6 | missions |
| ⌘7 | sessionLogs |
| ⌘8 | memoryReview |
| ⌘0 | controlDeck (deliberately excluded from `primarySections`) |

`overview` and `insights` are sidebar-only by design — meaning **the two screens a new user is most likely to want have no keyboard shortcut**, while `memoryReview` has one.

**System B — the toolbar deck strip**, which surfaces a *third* set: overview, controlDeck, charts, insights, projects, sessionLogs. Four of those six are not in `primarySections`.

**System C — `NavigationCoordinator`** (`AgentLens/Services/NavigationCoordinator.swift:33-41`), a mirror enum used for deep links and cross-window coordination:

```swift
enum DashboardRoute: Hashable {
    case overview, charts, database, projects, sessionLogs, chat
    case inbox(itemID: String?)
}
```

**Seven cases. `quota` is not one of them.** The `openburnbar://` deep-link handler (line 84-96) only understands `inbox`. So a pre-limit alert — the product's single most valuable interrupt — has no route to land on the quota screen. This is the highest-leverage two-line fix in the navigation layer.

Plus: `ControlKind` (`AgentLens/Models/ControlDeck/ControlKind.swift:76-88`) — 11 more tiles (engineRoom, aiInbox, modelRouter, wand, textExpansion, memoryMCP, charts, alerts, appearance, pets, updates). And `SettingsTab` (`AgentLens/Views/Settings/SettingsTab.swift:7-24`) — 17 panes. And the popover's 6 reorderable sections (`MenuBarPopoverView.swift:1568-1575`: insights, summary, providers, mercury, chat, quickSwitch).

**Total top-level destinations a day-one user can reach: 11 + 11 + 17 + 6 = 45.** Forty-five. That is the "forty things" problem, counted.

### 1b. What must exist instead

**Four destinations. One Settings window. Two tray sections.** Nothing else is top-level.

| # | Destination | ⌘ | Contains | Replaces |
|---|---|---|---|---|
| **0** | **The menu bar readout** (not a route — the product's home) | — | Tightest window across all connected agents, as `%` + reset clock, rendered as *text*, not an icon | `MenuBarLabel.swift` icon-only + hover tooltip |
| **1** | **Headroom** *(today: `quota`)* — **default landing** | ⌘1 | Per-account subscription cards, the reset atlas, urgency sort, one-click account switch inline on every drained card | `quota` (⌘3) + `AgentLens/Views/Dashboard/Quota/` |
| **2** | **Spend** *(today: `overview` + `charts`)* | ⌘2 | One layout. Stat row, cost curve, provider/model/project lanes, **3** charts (burn over time, provider mix, cache savings), and a single deterministic "what changed" strip carrying the AI Inbox's ranked findings | `overview` + `charts` + `insights` + `inbox` |
| **3** | **Sessions** *(today: `sessionLogs`)* | ⌘3 | Indexed transcript browser, one search box (hybrid FTS+vector), resume/handoff | `sessionLogs` (⌘7) + `database` (⌘4) atlas mode |
| **4** | **Labs** | ⌘4 | Single container, off by default, one warning header: chat, missions, memory review, projects, insight canvases, database system inspector, computer use, phone link, parallel runs | `chat` ⌘2, `missions` ⌘6, `memoryReview` ⌘8, `projects` ⌘5, `insights`, `database`, `controlDeck` ⌘0 |
| — | **Settings** (⌘,) | — | 5 panes: General · Agents · Alerts · Cloud · Advanced | 17 panes |
| — | **Tray popover** | — | **2** sections, fixed, non-resizable: (a) tightest window + reset clock, (b) switch account | 6 drag-resizable sections |

**Deleted outright: the Control Deck.** Its own subtitle — "Every feature, live, one click deep" — is a confession that the app has too many features to find. A 4-destination app does not need a feature browser. `AgentLens/Views/Dashboard/ControlDeck/` and `ControlKind.swift` go to Labs-only diagnostics or the bin.

**Route-enum consolidation is mandatory.** `NavigationCoordinator.DashboardRoute` must be deleted and `DashboardMainRoute` used directly, or the two must be made isomorphic. Three enums cannot describe four destinations. And `handleDeepLink` must learn `openburnbar://headroom` and `openburnbar://headroom/<provider>` so an alert lands on the drained card.

### 1c. Before/after, at a glance

| | Today | After |
|---|---|---|
| Dashboard routes | 11 + controlDeck + dynamic | **4** |
| Route enums | 3 (`DashboardMainRoute`, deck strip array, `NavigationCoordinator.DashboardRoute`) | **1** |
| Deep-link targets | 1 (`inbox`) | **2** (`headroom`, `sessions`) |
| Default landing | `overview` (empty state: "Welcome to OpenBurnBar") | **Headroom**, with a real number |
| Control Deck tiles | 11 | **0** |
| Settings panes | 17 | **5** |
| Tray sections | 6, drag-resizable, reorderable | **2**, fixed |
| Layout themes | 6 (`Views/Dashboard/Layouts/`) | **1** |
| Chart kinds | 14 | **3** |
| First-run steps | 7 (+ pet wizard, + switcher wizard, + Hermes wizard) | **0** |
| Reachable top-level destinations | **45** | **11** (4 routes + 5 settings + 2 tray) |

---

## 2. The demotion list

**Tier D0 — delete from the default path today (one-line or near-one-line fixes, highest damage prevented per byte)**

| Feature | File / view | Reason |
|---|---|---|
| Pet companion first-run window | `AgentLens/PetCompanion/Onboarding/PetOnboardingWindowPresenter.swift:14-15` (`openIfNeeded` force-activates ~1s after launch, gated only on `pet.firstRunCompleted`, not on `PetCompanionFeature.isEnabled`) | A spend tracker's first sentence to a new user must not be "choose your companion." |
| Delayed first scan | `AgentLens/App/AgentLensApp+LiveServices.swift:294-305` (30×1s sign-in poll + 15s sleep before `refreshAll()`) | 45 seconds of blank app before the one thing the product exists to do; the sign-in poll was never meant to gate the scan. |
| Menu bar icon-only label | `AgentLens/App/MenuBarLabel.swift:72-101` (`.labelStyle(.iconOnly)`, cost in hover tooltip) | The number the product is named for never appears in the menu bar. |
| Three chained consent modals | `AgentLens/Views/Dashboard/DashboardView.swift:581-598, 611-620, 621-632, 932-942` | Three privacy decisions asked before the user has seen a single number, so they have no basis to judge them. |
| Popover onboarding one-way door | `MenuBarPopoverView.swift:163` (`&& totalUsageSessionCount == 0`); `OnboardingView.swift:53-73` (prominent button is the skip) | The designed onboarding vanishes the moment the scan finds data, and its visually dominant button opts you out permanently. |
| Wizard re-entry with `nil` aggregator | `AgentLens/Views/Settings/GeneralSettingsView.swift:224-231` → `OnboardingScanView.swift:81` | The only durable re-entry hangs on "Scanning…" forever. |
| 7-step onboarding wizard | `AgentLens/Views/Onboarding/OnboardingWizardView.swift` (36 provider pills, 4-page tour, 12 TCC prompts, 12 chat toggles) | The core function needs zero permissions and zero choices — it reads files in `~`. |

**Tier D1 — move to Labs (kept, compiled, off by default, one warning header)**

| Feature | File / view | Reason |
|---|---|---|
| Multi-backend chat workspace | `AgentLens/Views/Chat/` (12 backends, 4 presentations) | Load-bearing for other surfaces, but it is a second product; one presentation, not four, and never in first run. |
| Insights canvases | `AgentLens/Views/Insights/InsightsWorkspaceView.swift` + 9 siblings | Fifth "AI explains your usage" surface; collapses into one deterministic strip on Spend. |
| Missions lane + console + FAB | `MissionsLaneView.swift`, `MissionConsoleWindowController.swift`, `MissionFAB.swift` | Mission Control's own source comment calls it "experimental infrastructure built ahead of user validation." |
| Projects + project memory | `ProjectsView.swift`, `ProjectsView+Memory.swift`, `ProjectMemory*Primitives.swift` | A sixth AI-explains-your-usage surface wearing an editorial hat. |
| Memory review inbox | `AgentLens/Views/Memory/MemoryReviewInboxView.swift` | Owns ⌘8 today for a governance queue that only matters once chat is used. |
| Database workspace (story / system modes) | `DatabaseWorkspaceView.swift` + 5 extensions | A SQL browser inside a menu-bar meter is the clearest example of off-mission surface area; keep atlas retrieval inside Sessions. |
| The Wand (fan-out) | `MacWandComposerSheet.swift` | Hidden already; it is also the sole justification for the Cloud Pro tier being collapsed. |
| Elder Wand (fusion) | `AgentLens/Views/Chat/ChatPanel.swift:535,776`, `ChatGatewaySettingsView.swift:84-87` | A documented paid feature the pricing page never lists, colliding by name with a different Wand. |
| Agent Control / Computer Use | `AgentLens/Views/ComputerUse/ComputerUseSettingsView.swift`, `SettingsTab.computerUse` | Self-flags "launch gates still open"; compiles out entirely under `DISTRIBUTION_MAS`; drags 12 TCC prompts into first run. |
| Mercury / Floo | `AgentLens/Views/Media/`, `MediaPermissionsView.swift`, popover `mercury` section | The phone-control category was commoditized by Anthropic, Cursor and OpenAI inside five months — all free. Keep the crypto, flag the surface off. |
| Chart Studio / 11 of 14 chart kinds | `AgentLens/Views/Charts/ChartKit/`, `ChartsReorderableGrid.swift`, `ChartAIInsightCard.swift` | Nobody has ever bought a menu-bar utility for its chart library. |
| Org rollup | `AgentLens/Views/Dashboard/OrgRollupView.swift` | Not a demotion — a **promotion target**: shipped code with zero call sites that becomes the Team tier's main screen. Stays dark until Team ships. |

**Tier D2 — move into Settings (reachable, not top-level)**

| Feature | Destination pane | Reason |
|---|---|---|
| Model proxy gateway + router | Settings → Advanced (`SettingsTab.modelProxy`) | Invisible plumbing nobody buys; ships free, never sold, host/port/token buried. |
| Routed-client wiring | Settings → Agents | Adoption unlock, not a destination. Delete the vestigial `CursorConnector.RoutedClientTarget` (2 cases) so there is one wiring path. |
| Engine Room / daemon | Settings → Advanced (`SettingsTab.daemon`) | Repair matters; its plumbing does not belong in navigation. |
| Vendor billing-API reconciliation | Settings → Advanced | A confidence badge on the number, never a pricing-page feature; needs Admin keys pasted in. |
| Smart displays / Cast / pixel clock | Settings → Advanced | Ambient toys behind a 5-step wizard. |
| Text expansion | Settings → Advanced | Unrelated to metering; keep, hide. |
| Appearance / 30 WebGL kernels / wallpaper | Settings → General, collapsed to **one** toggle | Thirty kernels is a gallery, not a preference. |
| Account switcher onboarding | Folded into Headroom | Kill the separate 3-step wizard and `hasSwitcherOnboarded` flag; the switch belongs on the drained card. |

**Tier D3 — delete from the repo**

| Item | Path | Reason |
|---|---|---|
| Settings Copilot | `AgentLens/Views/Settings/Copilot/SettingsCopilotController.swift` | Shipping an AI to navigate your own preferences is a confession, not a feature. With 5 panes it has nothing to do. |
| Settings search engine | `AgentLens/Views/Settings/Search/SettingsSearchEngine.swift` (75-item manifest) | Same. |
| Control Deck | `AgentLens/Views/Dashboard/ControlDeck/`, `ControlKind.swift` | A feature browser is a symptom. |
| Orphaned Python trees | `gateway/`, `hermes_cli/`, `tui_gateway/` | Zero tracked files; stale `__pycache__` from an unrelated project. |
| Dead Homebrew cask | `homebrew/burnbar.rb` | All-zero `sha256`, version 1.0.3 against shipped 1.0.29+, points at a tap repo that does not exist. |
| Console experimental gallery | `apps/console/src/app/experimental/` | Internal kernel picker on a members' privacy console. |
| Cloud Pro + Ultra + 4 top-ups | `packages/entitlements/src/catalog.ts` (stop selling; keep honoring) | Ultra has **zero** upsell call sites on any platform; Pro's content is exactly what this plan hides. |

---

## 3. The website story

### What the site says today

- `/index` H1 (`index.astro:79-87`): **"Watch your agents. Before the bill."** Sub: "Your agents don't send a receipt. We do. Live in the menu bar, from local logs. No telemetry. No account." Then the page pivots **nine more times** — H2s at lines 194, 254, 289, 316, 336, 392, 543, 587, 642, 660: "A developer tool, not a SaaS dashboard" → "What a calm console looks like" → "The list of vendors it actually understands" → "Nine surfaces, one daemon" → the Router → "A messenger for your own data" (Hermes) → "It doesn't just watch. It reaches." (Floo + Agent Control) → "By default, OpenBurnBar collects nothing" → pricing → "Don't get burned."
- `/product` H1 (`product.astro:26`): **"Every agent, every model, every dollar — in one calm console."** Then 9 H2 sections: tracking, routing (two failover postures with a paragraph of wire-format nuance), Hermes, surfaces, Floo, Agent Control, platforms, "What it doesn't pretend", "Read it in code."
- `/pricing` H1 (`pricing.astro:30`): **"Free where it should be. Paid where it costs us money."** Four tiers, a `WandPricingModule`, top-ups, and — critically — an FAQ that says *"No introductory offer is promised."*

The hero is right. Everything after it is a different company.

### What they must say

**`/index` — replacement hero** (honoring `website/CLAIMS.md`: every line below is followed by the evidence row it needs)

> **eyebrow:** For anyone running more than one coding agent
>
> # You are going to run out. Now you'll know which one.
>
> BurnBar puts one number in your menu bar: how much you have left across every AI coding agent you pay for, and when each window resets. It reads the logs already on your Mac — no account, no API key, no setup. When a window drains, it switches that CLI to your other account in one click.
>
> **[ Download for Mac — {SITE.macReleaseLatest} ]**  [ How the number is calculated ]
>
> ● Real quota signal from {QUOTA_SIGNAL_PROVIDERS.length} providers · ● No telemetry by default · ● Reads logs, not your API keys

Claims discipline for each new line:

| New claim | Evidence row to add to `CLAIMS.md` |
|---|---|
| "one number … across every agent you pay for" | `quotaSignalProviders` (18 today) + `AgentLens/Services/ProviderQuota/` — **must be computed**, not hardcoded, mirroring the existing `PROVIDERS_PRIMARY.length` pattern in `website/src/data/providers.ts` |
| "reads the logs already on your Mac — no account, no API key" | `README.md:57` verbatim; `ParserRegistry` (32 parsers) |
| "when each window resets" | `docs/PROVIDERS.md` 5h/7d/weekly windows; `QuotaRefreshActor` |
| "switches that CLI to your other account in one click" | account-switcher service (16 CLIs discovered) — **[verify]** which CLIs the switch is proven on |
| **Forbidden:** "stops", "blocks", "caps your spend" | `BudgetRule.swift:84` short-circuits subscription credentials to `.allow`, and the daemon `RoutePipeline` contains no budget check. Ship the word **"warns."** |
| **Forbidden:** "Nine surfaces" | `index.astro:39-43` *throws a build error* if the heading stops matching `SURFACES.length`. Cutting to Mac + iPhone requires editing the array and the guard in the same commit. |

Cut from `/index`: the Hermes section (392), the Floo/Agent Control section (543), the Router deep-dive (336) — demoted to one line — and the "Nine surfaces" band (316), replaced by "Mac and iPhone." The page goes from **ten** messages to **four**: the number, what it costs you not to have it, the action when it drains, the privacy model.

**`/product` — replacement**

> # Four things, and nothing else.
>
> **1. The number.** The tightest window across every agent you've connected, in your menu bar, as a percentage and a clock. Not dollars — dollars are an estimate; a window is a fact.
> **2. The atlas.** One screen with every plan you pay for and exactly when each resets.
> **3. The warning.** A cross-vendor alert at 80% — "Claude weekly at 91%, Cursor pool at 78%" — a sentence no vendor will ever send you, because it names their competitor.
> **4. The switch.** When one drains, move that CLI to your second account in one click and keep working.
>
> *What it doesn't do:* it doesn't stop a spend. It warns. The gate that would block a subscription-plan agent mid-window isn't built yet, and we won't sell it until it is.

That last paragraph is the strongest thing on the site and costs nothing — `/product:284` already has a "What it doesn't pretend" section to house it.

**`/pricing` — replacement**

> # Free where it should be. Paid where it costs us money.
>
> **BurnBar Local — $0, no account, no card.** Every agent, one number, 30 days of history, one Mac.
> **BurnBar Cloud — $7.99/mo · $79/yr.** Your windows stay current while your Mac sleeps, and your history outlives what the vendors delete. *(That's a server we pay for. It's the only honest reason to charge.)*
> **BurnBar Team — $15/seat/mo.** *(Coming; not yet purchasable.)*

Concrete edits to `pricing.astro`: delete the `WandPricingModule` import and render (lines 5, 40); delete the "How does The Wand scale across plans?" definition; delete the top-up definitions and the `allowance` destructuring (lines 11-19); drop Cloud Pro and Ultra from `SITE.pricing.tiers` with a grandfather note. **And the "No introductory offer is promised" answer (lines 61-63) must flip in the same commit as the 30-day reverse trial**, along with `CLAIMS.md:168` — those two are pinned to each other by the claims matrix, and shipping one without the other breaks the honesty discipline the site is built on.

**Also fix, because CLAIMS.md already flags or misses them:** the version pin (`site.ts` says 1.0.29, `project.yml:16` says 1.0.34); the canonical GitHub org (`Ajnunezg` vs `Imagine-That-Ai`, open `[verify]` #1); the `/mcp` self-contradiction (hero "Thirty-four MCP tools" vs its own verify snippet "PASS tools/list (8)"); and `/router/daily`, which promises a rundown "once every twenty-four hours" against a history folder whose newest file is five weeks old. `/router`, `/mcp`, `/platforms` and `/trust` have **no CLAIMS.md section at all** — and `/trust`'s headline is "This page fact-checks itself."

---

## 4. The naming problem

Ten names for one product. The rule going forward: **the user learns exactly one product name and eight nouns. Everything else is internal.**

**External vocabulary — the complete list**

| Word | Means |
|---|---|
| **BurnBar** | the product, the app, the brand, the repo, the domain |
| **agent** | Claude Code, Codex, Cursor — a thing you run |
| **account** | one subscription on one vendor |
| **window** | a 5-hour / weekly / monthly quota period |
| **headroom** | how much of a window is left |
| **reset** | when a window rolls over |
| **alert** | the warning before you drain |
| **switch** | moving a CLI to another account |
| **Cloud** | the paid tier |

**Codename map**

| Internal codename | Where it lives today | User-facing term | Rule |
|---|---|---|---|
| **OpenBurnBar** | `SITE.name`, every empty state ("Welcome to OpenBurnBar"), bundle `com.openburnbar.app`, README | **BurnBar** | Retire as a user-facing name. Keep only in the bundle ID, package namespaces, and the AGPL `NOTICE`. `NAMES.md:9`'s brand/OSS split is the source of the confusion — collapse it. |
| **AgentLens** | the entire macOS source tree | — | **Internal only, never shown.** Rename the directory when convenient; it is not ship-blocking, but no string in it may reach a user. |
| **Hermes** | chat UI, gateway, relay, mobile chat, `docs/HERMES_*.md` | **Chat** (in Labs) | Internal only. The name is inherited from an upstream dependency and means nothing to a buyer. |
| **Mercury** | Mac⇄phone media transport | — | **Internal only.** |
| **Floo** | public name for Mercury on burnbar.ai | **Phone link** (Labs) | Demote. One plain noun, or nothing. |
| **Elder Wand** | model fusion, Cloud Pro | — | **Internal only, feature off.** Unsellable as shipped: documented as paid, absent from the pricing page, absent from the Kotlin catalog, and name-colliding with a different Wand. |
| **The Wand** | parallel fan-out, tier ladder 1/3/8/16 | **Parallel runs** (Labs) | Demote. A tier ladder cannot rest on a hidden feature. |
| **Pensieve** | E2EE agent memory, the Ultra SKU | **Memory** (Cloud) | Internal only. |
| **Horcrux** | sealed-envelope relay crypto | **"sealed"** | Internal only. `/trust` may describe the property; never the codename. |
| **Smart Hub** | Cast / Nest Hub / Home Assistant bridge | **Displays** (Settings → Advanced) | Internal only. |
| **Mission Control** | daemon project/mission runtime | — | **Internal only.** |
| **Agent Watch / Agent Live Stage / Hermes Square** | mobile mirror surfaces | — | Internal only. |
| **Ministry / Castle** (MCP tool prefixes) | 68-tool local MCP server | — | Internal only; rename tools to `burnbar_*` before anyone integrates against them. |
| **Agent Control** | public name for Computer Use | **Computer use** (Labs) | Plain language. Two brand names for one capability is one too many. |
| **Signalification** | libsignal migration program | — | Internal only. |
| **mnemo** | Pensieve entitlement id family | — | Internal only. |

`NAMES.md` already states the policy — *"marketing surfaces never expose internal codenames"* — and the homepage violates it by mixing OpenBurnBar and BurnBar within one scroll. Enforce it with a build-time grep in the same CI job that already gates `PROVIDERS_PRIMARY.length` and the crypto-claims codegen: **fail the website build if any of the 13 codenames above appears in rendered copy.** That is a two-hour job and it never regresses.

---

## 5. Sequencing: 30 / 60 / 90

Ordered by leverage. **[SHIP-BLOCKING]** = the 1.1 release does not go out without it.

### Days 0–30 — "the app says one thing"

| # | Item | Blocking? |
|---|---|---|
| 1 | Gate `PetOnboardingWindowPresenter.openIfNeeded` on `PetCompanionFeature.isEnabled` | **[SHIP-BLOCKING]** — one line, prevents the worst first impression in the product |
| 2 | Hoist `refreshAll()` out of the sign-in poll (`AgentLensApp+LiveServices.swift:294-305`); scan on first launch | **[SHIP-BLOCKING]** — turns 45s of blankness into ~2s of a real number, the one thing no competitor can match |
| 3 | Render the number in `MenuBarLabel.swift` — percentage + reset clock, not dollars, not a tooltip | **[SHIP-BLOCKING]** |
| 4 | Collapse to 4 routes; delete `NavigationCoordinator.DashboardRoute`; make Headroom the default landing; add `openburnbar://headroom` | **[SHIP-BLOCKING]** |
| 5 | Tray: 6 sections → 2 (tightest window, switch account); drop resize/reorder and the `hasResetScrambledPopoverLayoutV2` migration debt | **[SHIP-BLOCKING]** |
| 6 | Delete first-run wizard, tour, TCC block, chat-engine step; defer all three consent modals until after the number is on screen, asked one at a time in context | **[SHIP-BLOCKING]** |
| 7 | Fix the popover gate (`MenuBarPopoverView.swift:163`) and button hierarchy (`OnboardingView.swift:53-73`); pass a real aggregator at `GeneralSettingsView.swift:227` | **[SHIP-BLOCKING]** |
| 8 | Reconcile the three quota/scan empty states so they give one next action (today: "Scan for Sessions" vs "Connect a provider account" vs "Click Scan") | **[SHIP-BLOCKING]** |
| 9 | Everything else behind a `Labs` flag, default off | **[SHIP-BLOCKING]** |
| 10 | Settings 17 → 5 panes; delete Copilot + search engine | not blocking (but do it now — it's cheap) |
| 11 | Instrument the one activation event: *user sees a real number for ≥1 provider within 60s of first launch* | **[SHIP-BLOCKING]** — without it, none of the above is measurable |

### Days 31–60 — "the story matches the app"

| # | Item | Blocking? |
|---|---|---|
| 12 | Cross-vendor pre-limit alert at 80%, naming two vendors in one sentence, deep-linking to Headroom | **[SHIP-BLOCKING]** for the pitch (it is the product's reason to exist) |
| 13 | Account switch inline on every drained Headroom card; delete the separate switcher wizard + `hasSwitcherOnboarded` | **[SHIP-BLOCKING]** |
| 14 | Website: new `/index`, `/product`, `/pricing`; update `SURFACES` + the `index.astro:39-43` build guard in the same commit; add CLAIMS rows for every new line | **[SHIP-BLOCKING]** |
| 15 | Naming enforcement: BurnBar everywhere in copy; CI grep for the 13 codenames | **[SHIP-BLOCKING]** |
| 16 | Collapse tiers: stop selling Cloud Pro, Ultra, and the 4 top-ups; grandfather every existing subscriber forever | **[SHIP-BLOCKING]** for pricing honesty |
| 17 | 30-day reverse trial, no card, landing softly on Local — plus flip `pricing.astro:61-63` and `CLAIMS.md:168` in the same commit | **[SHIP-BLOCKING]** — there is currently *zero* trial of any kind |
| 18 | Close the free Linux cloud replica hole (`functions/src/callables/linuxCloudReplica.ts` — auth + App Check only, no entitlement assert) | **[SHIP-BLOCKING]** — it gives the entire paid tier away |
| 19 | Resolve hosted-MCP tier mismatch **down** to Cloud (server already serves it there; the client blocks paying subscribers) | not blocking |
| 20 | Stripe handoff for the direct-download Mac build (today: `productUnavailable` + a bare link to `/pricing`) | **[SHIP-BLOCKING]** for revenue |
| 21 | Fix version pin (1.0.29 → current), canonical GitHub org, `/mcp` self-contradiction, stale `/router/daily` | not blocking |
| 22 | Retarget iOS Live Activities + 6 widget families from dollars to quota headroom (App Group snapshot type is already shared) | not blocking — high leverage, low cost |

### Days 61–90 — "the moat, and the second buyer"

| # | Item | Blocking? |
|---|---|---|
| 23 | **Enforce the budget gate in the daemon `RoutePipeline`** — the highest-value engineering left in the catalog. Until then the word on the site is "warns." | not blocking (blocking for ever saying "stops") |
| 24 | Establish on the record whether Claude Max / Cursor Pro / ChatGPT-plan subscription auth may legally and technically route through a third-party local proxy. **No pricing may rest on the router until this is answered.** | not blocking; **gates** items 25–26 |
| 25 | Promote quota-drain failover from Labs to the automatic upgrade behind the account switch — *only if* 24 clears | no |
| 26 | Consolidate the three search implementations (app `SearchService`, daemon `BurnBarIndexedSearchService`, MCP Python) into one before selling search | no |
| 27 | Merge agent memory and Project Code Memory into one namespace before either is sold | no |
| 28 | **BurnBar Team, $15/seat/mo, 3-seat minimum** — wire `OrgRollupView.swift` (shipped, zero call sites) to its live data layer (`fetchOrgRollup`) and turn on `enterpriseOrgViewEnabled` | no — ship it *second*, after Cloud converts |
| 29 | Freeze Windows and Linux as marketed surfaces until one actually publishes (Windows' only release is an unpublished x64 draft; Linux's own ledger says 0/40 product requirements ready) | no |
| 30 | Delete `gateway/`, `hermes_cli/`, `tui_gateway/`, `homebrew/burnbar.rb`, `apps/pensieve-experience/`, console `/experimental` | no |

---

## The one-paragraph summary

Cut 45 reachable destinations to 11. Land on Headroom, not an empty Overview. Put the number in the menu bar where the product's name promises it is. Delete the pet from first run, delete the 45-second delay, delete the wizard, and let the app do in two seconds the only thing no competitor can do at all — because the data is already on disk. Say "BurnBar" and nothing else. Say "warns," not "stops," until the route pipeline earns the other word. Sell two tiers, not four, and give people a way to try one. Everything else — Hermes, Mercury, Floo, both Wands, Mission Control, the Database workspace, the pet, the pixel clock, thirty WebGL kernels — is real engineering that belongs behind a single door marked Labs, where it can wait for a product that has earned an audience.
