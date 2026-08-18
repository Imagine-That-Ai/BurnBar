# The Control Deck — macOS Dashboard Control Center

**Status:** Approved for implementation. Supersedes the three bake-off proposals.
**Base:** working tree at `fix/domain-core-signer-path-api-1.0.34`, i.e. *after* `DashboardRouteNavigator` landed. Every navigation call in this spec is `routeNavigator.navigate(to:)` / `resetNavigation(to:)`. There is no mutable `mainRoute` to assign.
**Paths** are repo-relative to the OpenBurnBar root.
**Every code fact in this document was read out of the tree**, not remembered. Line numbers are cited where they are load-bearing. Where a proposal's claim did not survive verification, §12 records the correction.

---

## 1. The problem

OpenBurnBar has a Command Deck that answers *"what am I burning?"* and a 17-pane Settings window that answers *"what preference did I set?"* — and nothing at all that answers *"what is running right now, and can I touch it?"* Sixteen shipped features are addressable only by navigating a sidebar whose last section is literally named **More**, where each row is a *label* ("Text Expansion — && triggers, snippets, keyboard sync, and LLM previews") rather than a *fact*. Meanwhile the state that proves each feature is alive — 7 memories waiting for review, 92% of the last 24 inbox checks found nothing to do, 6 routed clients wired, 3 MCP agents connected, Accessibility never granted so the keystroke tap has been dead for a month — lives scattered across five stores and is rendered together nowhere. The result is that a user cannot discover a feature they don't already know the name of, cannot tell a feature that is *off* from a feature that is *silently broken*, and has to open a modal window to flip a switch whose effect they can only observe on the page they just left.

---

## 2. Decision record

**Spine: The Control Deck.** A new full-width `DashboardMainRoute.controlDeck` rendering a dense, reorderable grid of live tiles, built on a verbatim clone of the shipped `ChartKind` / `ChartsPageLayout` / `ChartsReorderableGrid` contract and the shipped `ChartCardView` glass recipe. The governing rule, enforced per tile:

> **A deck control may flip a preference. It may never grant trust, egress data off-device, open a network listener, or destroy a ledger.**

And the rule that keeps it from decaying into a settings mirror:

> **Every tile renders one live fact read from real state. A tile that can only render a label gets cut, not shipped as a link.**

**Grafted from The Helm:**
- The **pure, testable attention layer** — `attention(from: ControlDeckSnapshot) -> ControlAttention?` over a value-type snapshot, so the alarm set is derived and unit-tested without mounting a view.
- The **Overview attention band**, which is the only *push* discovery mechanism any proposal offered. Grafted **with the judged fix**: it renders *above* the `dataStore.totalUsageSessionCount > 0` gate in `overviewRouteView`, so it also appears in the zero-session welcome state — the user with the most unknown features.
- The **"All systems nominal" collapsed line** and the **vitals rail**, compressed to five pills on the deck route.
- **`@AppStorage("dashboard.landingRoute")` + "Make this my home"**, which answers "redesign the home page" without forcing it on anyone.
- **Fixed groups, reorder within group** — the IA is the product; free-for-all reorder destroys it.
- **Build-gated tiles are absent, not greyed** — an App Store build must not advertise Computer Use.

**Grafted from the Control Wall:**
- **Tier-2 expand-in-place.** A tile grows span 1→2 and reveals its full control set without a navigation jump. This is what makes 21 tiles readable: the collapsed wall is calm, the depth is one chevron away, and Settings keeps only the genuinely heavy surfaces.
- **The "every tile carries a live fact" cut-rule** (above).
- **`SettingsManifest` / ⌘K search integration and a reciprocal Settings→Deck link** — the judges docked all three proposals for one-way discovery. Fixed here.
- **Severity-tinted attention cards** distinct from feature accents.

**Rejected outright:**
- **`SwitchToggleStyle` / stock `Toggle` on glass.** Verified: zero occurrences under `AgentLens/Views/Dashboard` and `AgentLens/Views/Charts` (the only `toggleStyle` calls there are `.checkbox`, in `MacWandComposerSheet.swift:118` and `Quota/SubscriptionCard.swift:440`). Repeating a bare AppKit switch fifteen times would make the deck read as a Settings pane wearing a glass coat, and a system switch paints a solid saturated accent fill — off the opacity ladder entirely. §6.3 defines `ControlSwitch`, built from the verified `ChartsPageView.aiToggle` idiom.
- **Nine-to-ten accents.** §6.2 fixes six, one per group, all six already in `ChartKind.accent` or adjacent to it. `DesignSystem.Colors.warning` is reserved *exclusively* for attention state, because it is byte-identical to `amber` in dark mode (both `FFA800`, `DesignSystem.swift:20,54`) and any tile that claims it permanently poisons the alarm layer.
- **A bare `gatewayEnabled` toggle.** Verified: `GatewaySettings.gatewayEnabled.didSet` only persists, and its sole reader is `OpenBurnBarDaemonManager+Lifecycle.swift:452` at daemon launch. Flipping it OFF on the deck would show an off switch while the gateway keeps serving provider credentials until restart. Click-through only. §5, row R-3.
- **`ChartCardChrome` / `.chartGlassCard()`.** Zero call sites in the target. The deck copies `ChartCardView.swift:52-72`, the recipe users actually see today. The divergence is flagged as its own decision in §11.

---

## 3. Where it lives

### 3.1 Route

`AgentLens/Views/Dashboard/DashboardNavigationModel.swift` — add `case controlDeck` to `DashboardMainRoute` (14th case) and the arms the compiler forces:

| arm | value |
|---|---|
| `title(activeChatBackend:)` | `"Control Deck"` |
| `systemImage(...)` | `"slider.horizontal.below.square.filled.and.square"` |
| `accent(...)` | `DesignSystem.Colors.ember` |
| `subtitle(...)` | `"Every feature, live, one click deep"` |

**Not added to `primarySections`.** Verified `DashboardNavigationModel.swift:25-33`: `primarySectionIndex` is `firstIndex(of:) + 1` into a positional array, and it drives ⌘1–⌘8. Any insertion renumbers every existing user's shortcuts.

### 3.2 Compiler-forced touch points

1. `DashboardView.detailView` — one arm: `case .controlDeck: ControlDeckView(...)`.
2. `DashboardSidebarView.routeWantsProviderSidebar(_:)` — add `.controlDeck` to the **false** branch. It is a full-width workspace like `.inbox`/`.quota`; the provider rail must collapse to `.detailOnly`. The switch is exhaustive, so this is compiler-forced.
3. `DashboardToolbarContent.quickAccessRoute(rawValue:)` (`:1243-1258`) — add `case "controlDeck": return .controlDeck` so it is pinnable into `dashboard.quickAccess.v1`.

### 3.3 Entry points — five, because one is not enough

The judges' sharpest shared criticism was that every proposal buried its own discovery surface. All five ship:

1. **Deck strip icon** — a 6th `dashboardDeckRouteButton(.controlDeck)` in `dashboardDeckLeading` (currently 5 × 38×38: overview/charts/insights/projects/sessionLogs). The block is `fixedSize`; six still fit.
2. **`DashboardSectionSwitcher`** — an explicit row below a `Divider()`, outside the `ForEach(primarySections)` at `DashboardSectionSwitcher.swift:41`, carrying the attention count through the existing `badge(for:)` map (`:22`). This is the browsable "what surfaces exist" menu; the Helm's omission of it was its worst discoverability hole.
3. **`CommandDeckPalette`** — an explicit entry (the palette enumerates `primarySections`, so a non-primary route needs one) **plus** every `ControlKind` indexed as a searchable palette row by `title` + `whyItMatters` + `searchKeywords`. Typing "accessibility", "telegram", or "snippet" into ⌘K must reach the deck.
4. **⌘0** — hidden zero-size button in the same `.background { }` `.opacity(0).frame(width:0,height:0).allowsHitTesting(false)` pattern as `sectionShortcuts`. Decoration, but free.
5. **Reciprocal link from Settings** — `SettingsHomeView`'s attention section gains an "Open the Control Deck" row, and every settings pane that has a deck tile gains a `.help()`-annotated deck glyph in its header. Discovery must be two-way; today it is proposed one-way in all three bake-off entries.

Plus the two that reach a user who never went looking:

6. **Overview attention band** (§4.4) — renders in *all six* dashboard layouts *and* the zero-session welcome state.
7. **`@AppStorage("dashboard.landingRoute")`** (default `"overview"`), read once in `DashboardView.onAppear` to seed `resetNavigation(to:)`. The deck's overflow menu carries "Make this my home", mirrored into General → Dashboard Defaults (`SettingsPageRoute.defaultView`).

### 3.4 Name collisions

`DataControlCenterView` already exists under `Views/Settings/DataControlCenter/`. New types: `ControlKind`, `ControlTileConfig`, `ControlDeckLayout`, `ControlDeckView`, `ControlTileView`, `ControlTileChrome`, `ControlSwitch`, `ControlDeckSnapshot`, `ControlDeckModel`, `ControlAttention`, `ControlDeckAttentionBand`, `ControlDeckVitalsRail`. "Deck" already means the Command Deck header; "Control Deck" is the deliberate sibling and the copy everywhere says so.

---

## 4. The design

### 4.1 Page shell — template `ChartsPageView.swift`

```
ScrollView
└ VStack(alignment: .leading, spacing: Spacing.lg)      // 16
  ├ header
  ├ vitalsRail
  ├ attentionRail        (only when non-empty)
  └ 6 × groupBlock
  .padding(Spacing.xl)                                   // 24
  .frame(maxWidth: 1180, alignment: .leading)
  .frame(maxWidth: .infinity)                            // centre on wide windows
.background(dashboardLiveBackdropActive ? Color.clear : DesignSystem.Colors.background)
.scrollContentBackground(.hidden)
.accessibilityIdentifier(OBBAccessibilityID.controlDeck)
```

### 4.2 Text wireframe (4-column, ≥1180pt)

```
┌───────────────────────────────────────────────────────────────────────────────────────┐
│  Control Deck                                             ┌ All ─ On ─ Needs you ┐ ⋯  │
│  14 of 21 on · $18.40 today · daemon healthy              └──────────────────────┘    │
│                                                                                        │
│  ⟨ DAEMON Healthy 1.4.2 ⟩ ⟨ ROUTER :8317 on ⟩ ⟨ CLOUD Pro ⟩ ⟨ PERMS 4/6 ⟩ ⟨ BUDGET 74% ⟩│
│                                                                                        │
│  ⚠ Text Expansion needs Accessibility   ⚠ 7 memories waiting   ⚠ Claude 5h at 94%   →  │
│                                                                                        │
│  CAST ────────────────────────────────────────────────────────────────────────────────│
│  ┌──────────────────┐ ┌──────────────────┐ ┌───────────────────────────────────────┐  │
│  │ ◆ THE WAND    ●  │ │ ◆ ELDER WAND  ⌄ │ │ ◆ MODEL ROUTER              ● Token ⌄ │  │
│  │                  │ │                  │ │                                        │  │
│  │ 8 workers · 2 up │ │ Research · 5→o5  │ │ 12 of 18 models advertised            │  │
│  │ ▁▂▅▇▅▂▁          │ │ ▁▃▂▆▄▇▂ $4.12    │ │ http://127.0.0.1:8317/v1        ⧉     │  │
│  │ [1][3][8][16]    │ │ [Research ⌄]     │ │ ● Gateway on  ● Token enforced        │  │
│  │ Casts in paral-  │ │ Which panel run  │ │ Serves Cursor, VS Code, and any        │  │
│  │ lel across …     │ │ s by default.    │ │ OpenAI-compatible client.              │  │
│  └──────────────────┘ └──────────────────┘ └───────────────────────────────────────┘  │
│                                                                                        │
│  SPEND ───────────────────────────────────────────────────────────────────────────────│
│  ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐ ┌──────────────────┐  │
│  │ ◆ CHARTS      ✦  │ │ ◆ ALERTS      ●  │ │ ◆ AI INBOX    ●  │ │ ◆ …              │  │
│  │ 9 of 14 shown    │ │ $18.40 / $25.00  │ │ 4 unread         │ │                  │  │
│  │ ▁▂▄▇▅▃▂▁▃▅       │ │ ▓▓▓▓▓▓▓░░░  74%  │ │ $0.62 of $2.00   │ │                  │  │
│  └──────────────────┘ └──────────────────┘ └──────────────────┘ └──────────────────┘  │
└───────────────────────────────────────────────────────────────────────────────────────┘

  ●  = ControlSwitch (capsule, not a system switch)      ⌄ = expand to Tier 2
  ✦  = AI/spend-bearing switch, whimsy tint              ⧉ = copy
  ⚠  = attention chip, warning tint, reserved
```

Expanded (Tier 2) — the tile takes span 2 and grows to a fixed 248pt plate:

```
┌───────────────────────────────────────────────────────────────────────────────────────┐
│ ◆ TEXT EXPANSION                                                          ●        ⌃  │
│                                                                                        │
│ 12 snippets · 9 enabled                                                                │
│ ● In OpenBurnBar    ⚠ Everywhere — macOS has not granted Accessibility                │
│ ─────────────────────────────────────────────────────────────────────────────────────  │
│ Expand in OpenBurnBar chat            ●        [ Grant Accessibility… ]                │
│ Expand in other Mac apps              ⚠        Allow LLM rewrite previews      ○       │
│ ;addr   ;sig   ;eta   ;wip   ;lgtm                        Edit snippets →              │
└───────────────────────────────────────────────────────────────────────────────────────┘
```

### 4.3 Header

`HStack(alignment: .center, spacing: Spacing.md)`:
- Leading `VStack(alignment: .leading, spacing: 3)` — `"Control Deck"` at **24pt bold rounded** `textPrimary`; below it an **11.5pt rounded** `textMuted` subtitle carrying live numbers: `"\(onCount) of \(shownCount) on · \(todaySpend) today · \(daemonManager.status.label.lowercased())"`.
- `Spacer()`.
- Trailing: a 3-segment filter capsule **All · On · Needs you**, built as the cheap `ChartsPageView.timeRangePicker` variant (`.padding(3).liquidGlassSurface(in: Capsule())`, selected pill `Capsule().fill(ember.opacity(0.2))`, labels 10pt bold rounded `.tracking(0.6)`); then a 30×30 `.liquidGlassInteractive(in: Circle())` overflow `Menu`: **Unhide tile ▸ · Reset arrangement · Make this my home · Open Settings…**

### 4.4 Vitals rail and attention rail

**Vitals rail** — one `HStack(spacing: Spacing.sm)` of five `toolbarPill()` capsules (`DashboardChromeComponents.swift:236`), 8pt bold tracked label over 11pt `monospacedDigit` value, each with a 5pt state dot and a click-through. `DAEMON` · `ROUTER` · `CLOUD` · `PERMS` · `BUDGET`. Sources in §5. Below 860pt it wraps to two rows; below 700pt it collapses to one summary pill opening a popover.

**Attention rail** — a horizontally-scrolling row of chips in the `BurnRailFilterChip` idiom (capsule, h10/v6, 12pt medium rounded, hover fill `warning.opacity(0.08)`, border `warning.opacity(0.55)` at lw 0.5). Every chip is **derived**, never hand-authored:

```swift
struct ControlDeckSnapshot: Equatable, Sendable { /* pure value type, no view deps */ }

enum ControlAttentionSeverity: Int, Comparable { case opportunity, degraded, blocking }

struct ControlAttention: Equatable, Sendable {
    let kind: ControlKind
    let severity: ControlAttentionSeverity
    let title: String          // "Text Expansion needs Accessibility"
    let cause: String          // one line, plain English
    let fix: ControlDeckAction // .grantAccessibility, .startDaemon, .signIn, .navigate(…)
}

extension ControlKind {
    func attention(from s: ControlDeckSnapshot) -> ControlAttention?
}
```

Because `attention(from:)` is pure over a value type, `ControlDeckAttentionTests` covers every alarm without mounting a view — the same discipline as the new `DashboardRouteNavigatorTests.swift`. Tapping a chip scrolls the grid to the tile and pulses it with the amber halo `.settingsAnchor(_:)` already paints, cleared after 1.4s.

**Empty state is information.** With zero attentions the rail collapses to one 28pt success line: `"All systems nominal · 21 features healthy · daemon 1.4.2"`. It is a `Button` navigating to `.controlDeck` when rendered on Overview.

**On Overview**, `ControlDeckAttentionBand` renders the top 3 by severity with a `"+N more →"` chip. Insertion point, in `DashboardView.overviewRouteView`, **above** the `if dataStore.totalUsageSessionCount > 0` gate — not inside it, and not in `conceptDetailsDrawer` (which is `@State private var expanded = false` and would hide the alarms). That placement gets all six layouts *and* the welcome state in one edit.

### 4.5 Tier discipline

| Tier | What | Where |
|---|---|---|
| 0 | Attention band / rail — 0–3 items, self-deletes when empty | Overview + deck |
| 1 | Collapsed tile — one live fact, one primary control, status ladder | deck |
| 2 | Expand in place — full control set for that feature, span 1→2 | deck |
| 3 | Deep link — CRUD, wizards, credentials, policy, destructive | Settings |

Tier 2 is what makes 21 tiles calm. Expansion re-packs the grid through the shared row packer under `DesignSystem.Animation.gentle` (`nil` under `accessibilityReduceMotion`).

---

## 5. The control table

**Direct** = the deck writes the value.
**CT** = click-through only; the deck renders status and deep-links.
**Confirm** = direct, but behind an explicit dialog or sheet.
**NEVER** = must not be one click; the reason is stated.

### CAST — accent `whimsy`

| # | Tile / control | Live fact it reads | Where the state lives | Mode | Notes |
|---|---|---|---|---|---|
| C-1 | **The Wand** — fan-out width capsule (1·3·8·16) | `"8 workers · 2 casting"` | ceiling from `WandFanOut.maxParallel(for: MacCloudEntitlementStore.shared.cloudTier)`; running casts from the mission host behind `.missions` | **Direct** | writes new `@AppStorage("wand.defaultWorkerCount")`, seeds `MacWandComposerSheet.workerCount`. Segments above tier render with a crest → `FeatureUnlockSheet` |
| C-2 | The Wand — **Cast…** | — | — | **CT** | opens `MacWandComposerSheet` (already hosted on `DashboardView`). A cast spends provider credits and can edit files; it must pass the composer's own `commandsAllowed` / `fileEditsAllowed` / `requireApproval` |
| C-3 | **The Elder Wand** — default preset `Menu` | `"Research bench · 5 models → o5 judge"` + `"$4.12 fusion · 34% of spend"` | `settingsManager.elderWand.activePreset`, `analysisModelIDs`, `judgeModelID`; spend from `FusionImpactLedger.totals(from:to:)` → `FusionVsNormalTotals` | **Direct** | `ElderWandSettings.setDefault(id:)` — local JSON in `elderWand.presets.v1`, re-sanitized to exactly one default by `presetsSanitized()`. Reversible, no spend |
| C-4 | The Elder Wand — panel roster, judge, `maxToolCalls` | — | — | **CT** | `agents.analysisConfigurator`; spend receipts at `agents.fusionImpact` |
| R-1 | **Model Router** — endpoint readout + copy | `"12 of 18 models advertised"`, `http://\(gatewayHost):\(gatewayPort)/v1` | `GatewaySettings.gatewayHost/.gatewayPort` (`Stores/GatewaySettings.swift:16,20`); counts from `ConnectionsViewModel.proxyModels` → `ProxyAdvertisedModel.advertised` / `.routeEligible` | **Direct** (copy only) | 1.5s "Copied" flash, lifted from `ModelProxySettingsView.proxyHero` |
| R-2 | Model Router — **Repair wiring** | `"6 clients wired"` / `"Cursor stale"` | `RoutedClientWiringSentry` | **Direct** | `sweepNow()` is idempotent and fail-safe |
| R-3 | Model Router — **gateway on/off** | `"Gateway on"` status dot | `GatewaySettings.gatewayEnabled` | **CT** | **Latency lie.** `didSet` only persists (`GatewaySettings.swift:12-14`); the sole reader is `OpenBurnBarDaemonManager+Lifecycle.swift:452` at daemon launch. Flipping OFF would show an off switch while the gateway keeps serving credentials. Upgrade to Direct only after a service-level observer lands (§9, PR2 extension) |
| R-4 | Model Router — **auth token**, **`allowUnauthenticatedLoopback`** | shield chip: green "Token enforced" / amber "Loopback open" | token is Keychain-backed via `SettingsSecretPersistence` against `OpenBurnBarIdentity.gatewayAuthTokenAccount`; the flag is on `GatewaySettings` | **NEVER** | The source comment states it: any same-host process could then POST to the gateway and spend the user's provider credits. Token is never rendered. CT to `daemon.gateway.authToken` |
| R-5 | Model Router — bulk per-provider advertise, `crossVendorDegradeEnabled` | — | — | **CT** | one stray click blanks the catalog every wired client depends on; cross-vendor substitutes a different vendor on the user's key and needs a daemon restart |

### SPEND — accent `ember`

| # | Tile / control | Live fact | State lives | Mode | Notes |
|---|---|---|---|---|---|
| S-1 | **Charts** — AI-insights switch | `"9 of 14 charts shown"` | `ChartKind.allCases.count` vs `ChartsPageLayout.decode(...).visibleConfigs.count`, key `chartsPageLayout.v1` (`ChartKind.swift:145`) | **Direct** | `@AppStorage("chartsPage.llmInsightsEnabled")`. This is the one Charts control that spends money; it belongs where you can see it is on. Fires the identical `Analytics` `setting_key: "charts_ai_insights"` |
| S-2 | Charts — show/hide chips | — | `ChartsPageLayout.setVisible` → `chartsPageLayout.v1` | **Direct** (Tier 2) | you re-arrange Charts from the deck; sharpest proof these are instruments, not links |
| S-3 | **Alerts & Digest** — spend threshold | `"$18.40 / $25.00"` | `AlertSettings.costAlertThreshold: Double?` (nil == off, persisted as paired `hasCostAlertThreshold` + `costAlertThreshold`) vs `dataStore.usageWindowSummary(for:)` | **Direct** | uses the shared `SettingsBindings.costAlertThreshold(_:)` `Optional<Double>`↔`Bool` adapter extracted in PR1, and the identical `Analytics.settingsChanged` `setting_key` |
| S-4 | Alerts & Digest — digest on/off + hour | `"On · 9:00 AM"` | `AlertSettings.dailyDigestEnabled` / `.dailyDigestHour` | **Direct** | **No latency lie.** `DailyDigestManager.activate(from:isEnabled:hour:)` registers a cadence that re-arms the pending notification every 15 minutes, reading both settings live, so a write from either surface takes effect without a reschedule call. The tile renders the resulting state and no longer needs `.degraded` |
| S-5 | **AI Inbox** — run switch, **Analyze now** | `"4 unread · $0.62 of $2.00 today"`, `"92% of the last 24 checks found nothing to do"` | unread from `dataStore.aiInboxUnreadCount()` (reuse `DashboardView.aiInboxUnreadCount`, refreshed off `Notification.Name("openburnbar.aiInbox.badgeRefresh")`); budget/spend/skip from `AIInboxSettingsModel` | **Direct** | daemon round-trip `daemon.inbox.config.update`. The tile renders the value the **daemon stored** after re-clamping, never the optimistic one, with the `isSaving` spinner inline |
| S-6 | AI Inbox — egress mode (Nothing / Local only / Cloud models) | chip in the daemon's own words | `AIInboxSettingsModel.config.egressMode` | **Confirm** on escalation | moving *to* "Cloud models" raises a `confirmationDialog` naming exactly what leaves the Mac. Every downgrade is one tap |
| S-7 | AI Inbox — phone sync (`AIInboxSyncService.preferenceKey`) | — | — | **CT** | off-device consequence |

### KNOW — accent `success`

| # | Tile / control | Live fact | State lives | Mode | Notes |
|---|---|---|---|---|---|
| K-1 | **Memory** — automatic extraction | `"7 memories waiting for review"` | reuse `DashboardView.pendingMemoryReviewCount` ← `runtimeContext.chatMemoryStore.pendingChatMemoryReviewCount(scope: MemoryScope(appID: "openburnbar"))`. **No second query.** | **Direct**, only when consent granted | binds `MemorySettings.memoryAutomaticExtraction`. Live status is the real three-lever `MemoryExtractionGate.isEnabled(consentGranted:automaticExtraction:remoteConfigEnabled:)` (`MemorySettings.swift:108`) |
| K-2 | Memory — first-time enable | — | `memoryConsentGranted` | **Confirm** | with consent ungranted the tile shows a **"Turn on memory"** button presenting the existing consent sheet. Consent (gate G0) is an affirmative act, never a bare switch |
| K-3 | Memory — fleet kill switch | grey non-actionable chip "Paused by OpenBurnBar" | `memoryExtractionRemoteConfigEnabled` (Remote Config) | read-only | without it the user's switch reads *on* while the loop is dead — a state nothing in the app surfaces today |
| K-4 | Memory — cloud backup opt-in | — | `memoryApprovedCloudBackupOptIn` | **NEVER** | off-device egress of derived memory. CT only |
| K-5 | **Memory MCP** — client roster + endpoint copy | `"3 agents connected · used 2h ago"` | `MacRemoteMCPClientStore.clients` (Firestore `users/{uid}/remote_mcp_clients`), `MacRemoteMCPClientRecord.activitySummary` | read-only | **Cost:** opens a Firestore snapshot listener. `startListening()` on **Tier-2 expand**, `stopListening()` on collapse — never at page appear, never at app launch. See §12-D7 for the observation bridge |
| K-6 | Memory MCP — **revoke client** | — | `ComputerUseSecurityCallableClient.callHighRiskOwnerAction("revokeRemoteMcpClient", …)` | **NEVER** | high-risk owner callable. Stays in `MacRemoteMCPConnectedClientsSection` behind its existing `confirmationDialog`. CT `cloud.overview` |
| K-7 | **Text Expansion** — in-app expansion, global expansion, LLM rewrite previews | `"12 snippets · 9 enabled"`, reach = "Everywhere" / "OpenBurnBar only" | booleans on `TextExpansionSettings` (`textExpansion.inAppExpansionEnabled` / `.macGlobalExpansionEnabled` / `.llmRewritePreviewEnabled`); counts via `dataStore.fetchTextExpansionSnippets()` (`DataStore+TextExpansionAccess.swift:13`) | **Direct** | no extra call needed: `macGlobalExpansionEnabled.didSet` posts `.textExpansionMacGlobalExpansionEnabledDidChange` and `TextExpansionRuntimeController` installs/tears down the CGEvent tap. Snippet count is cached on `ControlDeckModel` (which lives on `DashboardView`, because route views carry `.id(mainRoute)`), invalidated by `.textExpansionSnippetsDidChange` |
| K-8 | Text Expansion — **Grant Accessibility** | amber chip when `!AXIsProcessTrusted()` | TCC | **Direct** (a request, not a grant) | the switch **does not flip**; it calls `MacAccessibilityPermissionRequester.promptAndOpenSettings()` and the tile re-polls on `NSApplication.didBecomeActiveNotification`, because System Settings never notifies the app. Row is `#if !DISTRIBUTION_MAS` |
| K-9 | Text Expansion — snippet CRUD | — | GRDB | **CT** | the 280–360pt master–detail editor with trigger validation and the live sandbox stays single-homed. `textExpansion.snippets` |
| K-10 | **Data & Privacy** — inventory readout | `"3 sources · 4,812 chunks · 18 MB"` | Data Control Center inventory | read-only | one button, **Open Data Control Center**, presenting the existing 980×680 sheet. Every purge, export, recovery and panic control stays inside it. Locked behind `GatedFeature.dataVault`. **Fixes §8-P2:** this tile is the first real render site for `SettingsAnchor.dataControlCenterInventory` |

### WATCH — accent `amber`

| # | Tile / control | Live fact | State lives | Mode | Notes |
|---|---|---|---|---|---|
| W-1 | **Quota Watch** — display toggle, **Refresh quotas** | `"Claude 5h at 94% · resets 3:40 PM"` + top-4 ranked bars | `ProviderQuotaService.shared.snapshotsByProvider`; `errors[provider]` demotes a provider to a muted "unknown" row rather than a fake 100% | **Direct** | `quotaService.refreshIfNeeded(dataStore:)`. Confidence chip from `ProviderQuotaConfidence` |
| W-2 | Quota Watch — provider order | — | `smartDisplayOrder` / quota order | **CT** | a drag list. Deep-links `agents.quotaDisplay` because General → "Quota Watch & Order" has **no `SettingsPageRoute`** (§8-P3) |
| W-3 | **Notifications** — local pings, calendar | `"Local on · Telegram configured · Calendar off"` | `ControllerSettings` via the `settingsManager.controller*` facade | **Direct**, with honest latency | every write reaches the daemon only through `OpenBurnBarOperatingLayer.refreshControllerRuntime()` → `syncControllerNotificationConfiguration(from:)` (`OpenBurnBarDaemonManager+Controller.swift:175-217`) on the ≤5-minute cadence. PR2's `SettingsEffectsObserver` calls it on change for **both** surfaces; until then the tile shows `.degraded("Syncing to daemon…")`, and `"Waiting for daemon"` with an Engine Room link when the daemon is not `.healthy` |
| W-4 | Notifications — **Telegram bot token** | "Configured" / "Not configured" | Keychain via `SettingsSecretPersistence` against `OpenBurnBarIdentity.controllerTelegramBotTokenAccount` | **NEVER** | never rendered, never echoed. CT `notifications.telegram`, where it is a `SecureField` |
| W-5 | **Engine Room** — Start / Restart / Repair | `"Healthy · v1.4.2 · protocol 60"`, `versionMismatch` → amber "Protocol 59 vs 60" | `daemonManager.status` (`OpenBurnBarDaemonStatus`) | **Direct** | idempotent, fail-safe, and the fix for half the other tiles' degraded states. Sidebar says "Engine Room"; the pane's `navigationTitle("Daemon")` gets renamed to match (§8-P5) |
| W-6 | Engine Room — HTTP gateway enable | — | see R-3 | **CT** | opens a network listener |

### REACH — accent `blaze`

| # | Tile / control | Live fact | State lives | Mode | Notes |
|---|---|---|---|---|---|
| A-1 | **Agent Control** — **Panic halt** | `"Idle · Ask every step · 14 deny rules · chain a91f3c2e"` | `ComputerUseSessionPanelModel.isSessionActive` / `.liveTrustMode` / `.scopeRules.count` / `.auditHeadHashHex` | **Direct**, visible only while `isSessionActive` | **The model must come from `runtimeContext?.computerUseRuntimeController` + `configurePanelModel()`.** `panicHalt` is declared `public var panicHalt: () -> Void = {}` (`ComputerUseSessionPanel.swift:419`); only `ComputerUseRuntimeController.swift:334` binds it to `coordinator.panicHalt(source:)`. The settings view's detached fallback (`ComputerUseSettingsView.swift:806`) inserts an audit row and **halts nothing**. With a nil controller the tile renders `.unavailable("Runtime not started")` and **zero** controls |
| A-2 | Agent Control — **Start Session** | — | `startSystemSession()` | **NEVER** | starts a live agent-drives-your-Mac session at the current trust with no confirmation |
| A-3 | Agent Control — **trust mode raise** | shown read-only | `ComputerUseSessionCoordinator+Approvals.swift:215-237` | **NEVER** | `setTrustMode` clamps to downgrade-only *while a session is active*; a between-sessions raise is unguarded privilege elevation. Any control not routing through `coordinator.setTrustMode` bypasses R-L5 |
| A-4 | Agent Control — **OpenTimestamps notarization** | absent | `auditNotarizationOptIn` | **NEVER** | egresses the audit-chain root hash to a third party; deliberately double-gated behind a collapsed `DisclosureGroup` plus the opt-in. Not on the deck at all |
| F-1 | **Floo (Media & Sharing)** — permission requests | three chips: screen / camera / mic | `SystemPermissionMonitor.shared.snapshots` — the cached, deduped 5s tick. **Not** fresh `AVCaptureDevice.authorizationStatus` / `CGPreflightScreenCaptureAccess()` probes | **Direct** (a request, not a grant) | a denied chip opens the OS dialog or `x-apple.systempreferences:`. macOS makes the real decision. Re-poll on `didBecomeActive` |
| F-2 | Floo — remembered devices | `"2 remembered devices"` | shared `MercuryConsentStore`, ledger `mercuryMirrorAutoAcceptGrants.v2`, 30-day TTL | read-only | uses the runtime's instance, not a third `@StateObject` (see §12-D11) |
| F-3 | Floo — **`rememberAcceptedMirrorPeers`**, **Revoke remembered devices** | — | `MercuryConsentStore` | **NEVER, both directions** | ON converts future mirror accepts into 30-day device-bound auto-accepts that bypass the Accept tap (`canAutoAccept`); OFF *silently destroys every stored grant* — a de-facto revoke with no confirmation |
| D-1 | **Devices & Sync** — smart-display toggle + reorder | `"3 trusted devices · 1 pending"` (cached, with an "as of" stamp) | trusted counts from `DeviceTrustViewModel` behind an explicit **Check devices** button; display config from `QuotaSettings` JSON keys | **Direct** (smart displays only) | must copy the `.onChange` re-apply to `runtimeContext?.pixelClockController` / `smartDisplayRepairCoordinator` (`NestHubSettingsCard.swift:80-85`) or the device never repaints |
| D-2 | Devices & Sync — **approve / revoke device** | read-only | `MacDeviceTrustGateway` → `users/{uid}/escrow_devices` | **NEVER** | approve is a credential-trust grant (and its `DeviceTrustSafetyCompareSheet` is behind `EscrowDeviceTrustSafetyCheckFlag`, flag-OFF by default); revoke is a partially-async Cloud Vault key rotation that rewraps documents and storage blobs and can leave a pending requirement |
| B-1 | **Cloud** — tier + unsynced backlog | `Pro` crest; `"6 session logs waiting · checked 2m ago"` | `MacCloudEntitlementStore.shared.cloudTier` (read the **already-started** store; never call `.start()` — 5 Firestore listeners + a StoreKit task, and an off-window render wedges CI); backlog from `dataStore.countUnsyncedSessionLogs()` behind an explicit refresh | read-only + refresh | never `onAppear` — the settings path also runs `fetchChatThreadSummaries(limit: 500)` and `backupUsageSnapshot()` |
| B-2 | Cloud — **conversation backup enable** | — | `settingsManager.conversationBackupEnabled` — the **composite facade** (`SettingsManager.swift:662-668`) writing both `sessionLogCloudBackupEnabled` and `conversationCloudBackupEnabled` | **Confirm** | **The deck presents `SessionLogsCloudConsentSheet`; it never stamps `sessionLogCloudBackupConsentShown` itself.** That flag is read at `DashboardView.swift:634` and `DashboardConsentCoordinator.swift:24,64` to decide whether to *show consent at all*. Stamping it from a 16pt tile records the user as having seen consent they never saw. See §12-D6 |

### HOUSE — accent `frost`

| # | Tile / control | Live fact | State lives | Mode | Notes |
|---|---|---|---|---|---|
| H-1 | **Appearance** — skin, layout, glass transparency | `"Atelier · Editorial skin · glass +0.2"` | `AppSkin`, `DashboardLayout` (`dashboardLayout`), `liquidGlassTransparency` | **Direct** | embeds the existing `BurnRailAppearanceQuickMenu` and `DashboardLayoutSwitcher` as-is. Zero new logic; it just stops being hidden in a status rail |
| H-2 | **Pets** — companion toggle, pet picker, agent picker | `"Nimbus · Codex brain · ⌥⌘P"` | `@AppStorage` `pet.companionEnabled` / `pet.activePetID` / `pet.activeAgent` | **Direct** | routed through `PetCompanionFeature.toggleCompanion()`, which pairs the flag with `showCompanion()` / `closeBubble()+hideCompanion()`. A bare `@AppStorage` write is inert. Backends from `PetChatController.resolveAvailableBackends` — not re-filtered here |
| H-3 | Pets — hotkey chip | `"⌥⌘P"` | persisted `pet.hotkey.combo` string | read-only | **never** `PetCompanionFeature.runtime.hotkey.combo.displayString`: `runtime` is a `static let` whose first touch builds the controller, the Carbon global hotkey and `PetSystemObservers`. Rendering a chip must not boot a subsystem |
| H-4 | **Updates** — auto-check toggle, **Check now** | `"1.0.34 · up to date"` / `"1.0.35 available"` | update service + release channel | **Direct** | `#if !DISTRIBUTION_MAS`; the kind is **absent** from `ControlKind.visibleKinds` in MAS |
| H-5 | **Quick Access** — pinned-destination editor | `"7 pinned"` | `dashboard.quickAccess.v1` JSON | **Direct** | presents the existing `DashboardQuickAccessEditor`; extends the shipped rail rather than duplicating it |

### The exclusion list, stated once

Never one click from the deck, in any state, for any tier:
**Computer Use Start Session · Computer Use trust-mode raise · OpenTimestamps notarization · Mercury `rememberAcceptedMirrorPeers` (ON *or* OFF) · Revoke remembered mirror devices · Device approve · Device revoke · Remote MCP client revoke · Gateway auth token · `allowUnauthenticatedLoopback` · Gateway enable (until R-3's observer lands) · Telegram bot token · Memory cloud backup opt-in · Memory `deleteAll` · everything inside the Data Control Center.**

Behind an explicit confirm: **AI Inbox egress escalation to Cloud models · first-time memory consent · conversation cloud backup enable (via the real consent sheet) · index rebuild.**

Deliberately unconfirmed, and correct: **Panic halt** (fail-safe in direction), **every *off* direction** (turning things off is always one click), and **permission requests** (the OS dialog is the real gate).

---

## 6. Visual spec

### 6.1 The plate — `ChartCardView.swift:52-72`, verbatim

```swift
.padding(DesignSystem.Spacing.lg)                              // 16
.frame(maxWidth: .infinity, alignment: .leading)
.background {
    let shape = RoundedRectangle(cornerRadius: DesignSystem.Radius.lg, style: .continuous)  // 16
    if #available(macOS 26, *) {
        shape.fill(accent.opacity(colorScheme == .dark ? 0.08 : 0.04))
             .liquidGlassEffect(.regular, in: shape)
    } else {
        ZStack {
            shape.fill(.ultraThinMaterial)
            shape.fill(DesignSystem.Colors.surface.opacity(colorScheme == .dark ? 0.45 : 0.55))
            shape.fill(accent.opacity(colorScheme == .dark ? 0.08 : 0.04))
        }
    }
}
.overlay(shape.stroke(accent.opacity(0.22), lineWidth: 0.75))
.clipShape(shape)
```

On macOS 26 the accent wash is the **only** fill and it rides *on top of* the glass. Nothing opaque underneath — a material fill below real glass blocks refraction and reads as frosted plastic. That rule is in the source (`Theme/LiquidGlass.swift`, `MenuBarPopoverView.swift` `GlassCard`) and it is load-bearing.

**Expanded plate** — the sanctioned `DashboardLiveCostCurve.swift:66-87` variant: same material, same wash, stroke rises to `accent.opacity(0.32)`, plus `.shadow(color: accent.opacity(colorScheme == .dark ? 0.10 : 0.05), radius: 8, y: 4)`. Expansion reads as *lifted*, not as a different component.

**Attention plate** — stroke `DesignSystem.Colors.warning.opacity(0.55)` at lw **1.0**, wash `warning.opacity(dark ? 0.10 : 0.06)`, 6pt warning dot before the eyebrow, footer replaced by the fix verb. Still a wash tinting the light, never a red slab.

**Editorial-skin branch, required.** When `AppSkin.current == .editorial` the plate renders as crisp paper — `DesignSystem.Colors.surface` fill + 1pt `DesignSystem.Colors.border`, explicitly glass-free — the branch `SidebarThemeGlass` takes at `Theme/ThemeGlassPalette.swift:106-148`. `Color.adaptive(editorial:light:dark:)` resolves the editorial hex regardless of aqua/darkAqua, so a hard-coded glass plate looks wrong there. This is the single most common way a new AgentLens surface ships broken.

**Glass cannot sample glass.** Each group's tile rows are wrapped in `LiquidGlassGroup(spacing: DesignSystem.Spacing.md)` (`Theme/LiquidGlass.swift:301`). Inside a tile, **at most one nested real-glass control** (the primary `ControlSwitch`); every secondary control uses the non-glass capsule form in §6.3. Always `.liquidGlassEffect`, never SwiftUI's `.glassEffect`, so `liquidGlassTransparency` and Reduce Transparency survive.

### 6.2 Accent — six, one per group

Charts spends five hues across fourteen cards. The deck spends **six across twenty-one**, assigned per *group*, not per tile, and every one is drawn from the verified `ChartKind.accent` switch (`ChartCardView.swift:10-22`) or its documented siblings.

| Group | Accent | Token | `ChartKind` precedent |
|---|---|---|---|
| CAST | `whimsy` | `6A5ACD` / `8B7FE8` | `providerMix`, `modelMix`, `modelConcentration` — composition/mix |
| SPEND | `ember` | `F45B69` / `FA5053` | `burnOverTime`, `burnForecast`, `costPerSessionDistribution` — money |
| KNOW | `success` | `3A7835` / `38D898` | `cacheROI`, `provenanceQuality` — data quality |
| WATCH | `amber` | `F28C38` / `FFA800` | `hourOfDayHeatmap`, `weekOverWeekDelta` — time & attention |
| REACH | `blaze` | `E86100` / `E86100` | `reasoningShare` — high-consequence / off-device |
| HOUSE | `frost` | `5EB1EF` / `6FC2FF` | cooling spectrum; visible in both schemes |

**Reserved and unavailable to tiles:**
- **`warning`** — attention state only. It is `C47800`/`FFA800` (`DesignSystem.swift:54`), byte-identical to `amber` in dark. A tile that claims it becomes indistinguishable from the WATCH group *and* permanently occupies the alarm hue.
- **`glacier`** — `DesignSystem.Colors.planSpend` is `glacier` (`SpendLens.swift:39-42`, "plan-covered spend, cool against ember's heat"). Blue means subscription-covered money in the burn hero and Charts; it cannot also mean "infrastructure" one scroll below.
- **`abyss`** (`1B3A6B`/`12294D`) — at 0.08 wash and 0.22 stroke it is invisible on dark glass and imperceptible on light. It exists as the bottom stop of `coolDownGradient`, not as a card identity.
- **`hermesMercury`** (`AEA69C`/`C8BFB5`) and **`hermesAureate`** — Hermes *chat* identity. A desaturated warm grey plate next to ember neighbours reads as disabled.

Colour otherwise enters a tile only through its instrument ink and its status dots.

### 6.3 `ControlSwitch` — the on/off vocabulary

Modelled on `ChartsPageView.aiToggle`, read verbatim from the tree. No `Toggle`, no `SwitchToggleStyle`, no `Form`, anywhere on the deck.

```
Button { … } label: {
    HStack(spacing: 6) {
        Image(systemName: glyph)
            .font(.system(size: 11, weight: .semibold))
            .symbolEffect(.bounce, value: isOn)
        Text(label).font(.system(size: 11, weight: .semibold, design: .rounded))
        Circle()
            .fill(isOn ? DesignSystem.Colors.success : DesignSystem.Colors.textMuted.opacity(0.5))
            .frame(width: 5, height: 5)
    }
    .foregroundStyle(isOn ? accent : DesignSystem.Colors.textSecondary)
    .padding(.horizontal, 12).padding(.vertical, 8)
    .contentShape(Capsule())
}
.buttonStyle(.plain)
.liquidGlassInteractive(tint: isOn ? accent.opacity(0.4) : nil, in: Capsule())
.help(isOn ? onHelp : offHelp)
.accessibilityLabel(label)
.accessibilityValue(isOn ? "On" : "Off")
.accessibilityIdentifier(OBBAccessibilityID.controlDeckToggle(kind))
```

**Secondary controls inside a tile** (no nested glass): the `SpendLensPicker` segmented form (`SpendLens.swift:47-101`) with the glass background replaced by `Capsule().fill(accent.opacity(colorScheme == .dark ? 0.05 : 0.03))` and `Capsule().stroke(accent.opacity(0.18), lineWidth: 0.75)`; segment labels 9pt bold rounded `.tracking(0.4)`; selected fill `Capsule().fill(accent.opacity(dark ? 0.16 : 0.10))`. Numeric entry uses `DesignSystem.Typography.monoSmall` + stepper.

### 6.4 Typography — the Charts literals, not the tokens

| Element | Font |
|---|---|
| Page title | `.system(size: 24, weight: .bold, design: .rounded)` `textPrimary` |
| Page subtitle | `.system(size: 11.5, design: .rounded)` `textMuted` |
| Group eyebrow | `.system(size: 10, weight: .bold, design: .rounded)`, `.tracking(1.1)`, `.uppercased()`, `textMuted`, trailing `border.opacity(0.5)` hairline rule |
| Tile eyebrow | same as group eyebrow |
| Tile headline | `.system(size: 15, weight: .bold, design: .rounded)`, `.monospacedDigit()`, `textPrimary`, `lineLimit(1)`, `.contentTransition(.numericText())` with `DesignSystem.Animation.gentle` |
| Status ladder | `.system(size: 10.5, weight: .semibold)` `textSecondary` + 5pt dots (`SpendLens.swift:166-193` legendChip idiom) |
| Tile footer | `.system(size: 10, design: .rounded)` `textMuted`, `lineLimit(2)` |
| Vitals pill label / value | 8pt bold `.tracking(0.8)` / 11pt `.monospacedDigit()` |
| Attention chip | 12pt medium rounded |

**Headline budget: 28 characters.** At four columns a tile is ~274pt; `"Idle · Ask every step · 14 deny rules · chain a91f3c2e"` cannot survive `lineLimit(1)`. The headline carries the one number; the status ladder carries the rest.

### 6.5 Geometry

| | |
|---|---|
| Card radius | `DesignSystem.Radius.lg` = 16, `style: .continuous` |
| Card padding | `DesignSystem.Spacing.lg` = 16 |
| Page padding | `DesignSystem.Spacing.xl` = 24 |
| Content clamp | `.frame(maxWidth: 1180, alignment: .leading)` then `.frame(maxWidth: .infinity)` |
| Grid gutters | `DesignSystem.Spacing.md` = 12, rows and columns |
| Internal stack | `DesignSystem.Spacing.sm` = 8 |
| Glyph well | 26×26 `RoundedRectangle(cornerRadius: DesignSystem.Radius.sm)` filled `accent.opacity(0.14)`, glyph 12pt semibold `accent` |
| **Collapsed tile content height** | **fixed 108pt** → 140pt plate |
| **Expanded tile content height** | **fixed 216pt** → 248pt plate |
| Inline instrument | 34pt, dropped below 600pt container width |

The fixed heights are not cosmetic. `ChartCardView` gets row alignment for free from `.frame(height: 150)` on its chart body (`ChartCardView.swift:44`); without an equivalent rule, paired half-width tiles with variable content bottom out ragged in every `HStack(alignment: .top)` row.

Animations: `DesignSystem.Animation.gentle` for layout/expansion, `.hover` for the chevron fade, `.snappy` for selection; every one passed `nil` under `@Environment(\.accessibilityReduceMotion)`. Drop target: `ember.opacity(0.8)` stroke at lineWidth 2 + 1.01 scale, also reduce-motion gated.

Foreground colours come from `BackdropAdaptiveColors(profile: dashboardActiveReadabilityProfile)` published as `\.backdropReadabilityProfile`. **Never a seeded constant profile** — `nativeFallback(colorScheme:appearanceSkin:liveBackdropActive:)` is the correct pre-publish answer.

---

## 7. Tile states

Six states, uniform across all 21 tiles. This uniformity is what makes 21 plates read as one instrument.

| State | Plate | Control | Headline | Footer |
|---|---|---|---|---|
| **`.on`** | accent wash 0.04/0.08, stroke 0.22 | `ControlSwitch` lit, dot `success` | the live number | `whyItMatters` |
| **`.off`** | wash drops to the control-plate rung **0.03 light / 0.05 dark**, stroke 0.22 | `ControlSwitch` unlit, dot `textMuted.opacity(0.5)`, **still live** | the value it *would* control, in `textMuted` — never blanked (`"12 snippets ready"`) | the one-line reason to turn it on |
| **`.needsPermission`** | attention plate (warning 0.55 @ lw 1.0) | switch **replaced** by a `GlassButton(style: .prominent)` naming the grant: "Grant Accessibility…" | last known value | names the exact TCC permission |
| **`.locked(GatedFeature)`** | normal accent plate | tier crest (`GatedFeature.crestAssetName`) where the switch would be; tap → `FeatureUnlockSheet(feature:)` | **still readable** — `FeatureLockedVeil` covers only the value area, never the whole tile | what the tier would give |
| **`.unavailable(reason)`** | wash 0.03/0.05, grey dot | the **repair** action, not a dead link: Retry / Start daemon / Sign in | last known value or `"—"` | the reason, in the subsystem's own words |
| **`.degraded(note)`** | attention plate | live control **plus** an amber note | live number | `"Syncing to daemon…"` / `"Takes effect next launch"` |

Per-tile empty/unavailable copy, written out because "handle the empty state" is where specs rot:

| Tile | `.off` | `.unavailable` | `.needsPermission` |
|---|---|---|---|
| The Wand | `"1 worker · Free tier"` | — | — |
| Elder Wand | `"No preset — Charts model only"` | — | — |
| Model Router | `"Turn on to serve Cursor, VS Code, and any OpenAI-compatible client."` | `"Daemon not running"` → Start | — |
| Charts | `"AI insights off · 14 charts ready"` | — | — |
| Alerts & Digest | `"No spend alert set · $18.40 today"` | — | `"macOS has not allowed notifications"` → request |
| AI Inbox | `"Not running · 0 unread"` | `model.unavailableReason` → Retry (`load(forceTokenRefresh: true)`) | — |
| Memory | `"Extraction off · 7 memories waiting"` | `"Memory store not started"` | consent ungranted → "Turn on memory" |
| Memory MCP | — | `"Sign in to view connected MCP clients"` · `"Cloud is not configured on this Mac"` | — |
| Text Expansion | `"12 snippets ready · expansion off"` | — | `"Needs Accessibility"` → `promptAndOpenSettings()` |
| Data & Privacy | — | `"Vault not initialised"` | — |
| Quota Watch | `"Quota popover off · 6 providers tracked"` | `"No quota data yet"` → Refresh | — |
| Notifications | `"All channels off"` | `"Waiting for daemon"` → Engine Room | `"macOS has not allowed notifications"` |
| Engine Room | — | `"Not installed"` → Install · `"Protocol 59 vs 60"` → Repair | — |
| Agent Control | `"No session"` | **`"Runtime not started"` — and zero controls** | screen recording / accessibility not granted |
| Floo | — | `"Cloud is not configured"` | per-capability chips → OS dialog |
| Devices & Sync | `"Cloud sync off"` | `"Sign in to check devices"` | — |
| Cloud | `"Free tier"` | `"Not signed in"` | — |
| Appearance | — | — | — |
| Pets | `"Pet hidden · Nimbus selected"` | — | — |
| Updates | `"Automatic checks off · 1.0.34"` | `"Could not reach the update server"` → Retry | — |
| Quick Access | `"Nothing pinned"` | — | — |

**Build gates: absent, not greyed.** `ControlKind.visibleKinds` drops `.agentControl` and `.updates` under `DISTRIBUTION_MAS`, and Text Expansion's "Expand in other Mac apps" control is inside `#if !DISTRIBUTION_MAS`. To stop this drifting from `SettingsTab.visibleTabs` (`SettingsTab.swift:181-193`), PR1 extracts a single `OpenBurnBarBuildGates` enum with `agentControlAvailable` / `updatesAvailable` / `globalTextExpansionAvailable`, and **both** `SettingsTab.visibleTabs` and `ControlKind.visibleKinds` read it. A test asserts the two sets agree.

**Fresh-install first run.** With `dataStore.totalUsageSessionCount == 0` the deck would otherwise be a wall of grey off-states for exactly the user who needs it most. Instead the deck renders a single full-width **welcome tile** above the groups — `"Scan your sessions to bring the deck to life"` with the same Scan button `overviewView`'s welcome state uses — and the six `defaultVisible` tiles that work without data (Appearance, Pets, Text Expansion, Alerts, Engine Room, Updates) render normally beneath it. Everything else is hidden until the first scan completes.

**Default arrangement, enumerated.** `defaultVisible: true` for 15 kinds, in this order: Engine Room · AI Inbox · Memory · Text Expansion · Charts · Alerts & Digest · Quota Watch · Model Router · The Elder Wand · Agent Control · Cloud · Notifications · Appearance · Pets · Updates. `defaultVisible: false` for 6: The Wand, Memory MCP, Data & Privacy, Floo, Devices & Sync, Quick Access — each reachable from the header's **Unhide tile ▸** menu, and each auto-promoted to visible the first time it produces an attention.

---

## 8. Prerequisites the deck exposes rather than creates

These are real defects found in the tree. Four are one-file fixes and land with the tiles that depend on them (§9, PR2). Shipping a tile whose click-through silently fails to scroll is exactly the "labelled link into Settings" failure this design exists to end.

- **P1 — Daily Digest never reschedules. ~~Fixed~~ — no longer a prerequisite.** Resolved ahead of this design by `DailyDigestManager.activate(from:isEnabled:hour:)`, which registers a `BackgroundCadenceCoordinator` cadence that re-arms the pending notification every 15 minutes and reads `dailyDigestEnabled` / `dailyDigestHour` on each tick. Settings and the deck therefore both take effect on their own, structurally, with no per-surface reschedule call — so `SettingsEffectsObserver` (§9) does **not** need to own the digest. The same change replaced the repeating trigger that froze the digest body at launch.
- **P2 — `SettingsAnchor.dataControlCenterInventory`** (`"data.controlCenter.inventory"`) is declared and indexed in `SettingsManifest.anchorIndex` and referenced by manifest item `dataPrivacy.controlCenter.inventory`, but attached to **no view**. Attach it, and note the prefix mismatch between the item id and the anchor constant.
- **P3 — General → "Quota Watch & Order" has no `SettingsPageRoute`**, so it is the one drill row that cannot be deep-linked. Add the route; until then W-2 targets `agents.quotaDisplay` on a different tab.
- **P4 — Three anchors render outside `SettingsDeepLinkScrollContainer`**: `media.permissions`, `computerUse.readiness`, `computerUse.permissionsSetup`. `proxy.scrollTo` never fires. Media additionally uses a raw `.id(SettingsAnchor.mediaPermissions)` instead of `.settingsAnchor(...)`, so it also loses the arrival halo. Wrap all three.
- **P5 — Sidebar "Engine Room" vs `navigationTitle("Daemon")`** on the same pane. The deck says Engine Room; rename the pane.
- **P6 — `OBBAccessibilityID.dashboardDeckInboxButton`** (`AccessibilityIdentifiers.swift:26`) is declared with no call site. Wire it to the deck's inbox affordance or delete it.
- **P7 — Dead MAS branch:** `SettingsView.detailContent`'s `.computerUse` case renders `MediaPermissionsView` titled "Media & Sharing", but `visibleTabs` already filters `.computerUse` out of MAS. Delete it while extracting `OpenBurnBarBuildGates`.

---

## 9. Delivery — three PRs, each independently shippable and revertible

Each PR ends with a working app whose behaviour is strictly better than before it. No PR depends on a later one to be correct.

### PR 1 — Substrate, route, and the seven safe tiles

**Ships:** a working Control Deck route with seven tiles, all direct bindings, no new async, no new listeners.

- `AgentLens/Models/ControlDeck/ControlKind.swift` — `String, Codable, CaseIterable, Identifiable, Sendable`; each case carries `title`, `whyItMatters`, `systemImage`, `group`, `defaultSpan`, `defaultVisible`, `searchKeywords`, `gatedFeature: GatedFeatureID?`, `settingsItemID: String?`, `route: DashboardMainRoute?`. Group carries the accent; tiles do not.
- `ControlTileConfig` + `ControlDeckLayout` — the `ChartsPageLayout` contract verbatim, including forward-compatible `reconciled(_:)` (unknown kinds dropped, new kinds appended with defaults), JSON in `@AppStorage("controlDeck.layout.v1")`. Reorder is **within group only**.
- **Extract the row packer.** `ChartsReorderableGrid` is hard-typed (`let layout: ChartsPageLayout`, `let snapshot: ChartsSnapshot`, constructs `ChartCardView` directly at `:44`; `rows(for:)` takes `[ChartCardConfig]` at `:89`). Extract `CardRowPacker.rows(spans:columns:)` and a generic `ReorderableCardGrid<Item, Card>` into `AgentLens/Views/Components/`, **and refactor `ChartsReorderableGrid` onto it in this PR**. Charts must be pixel-identical after; a snapshot of `rows(for:)` output over the existing 14 `ChartKind` defaults is the regression gate.
- `ControlTileChrome.swift` (plate + six states + editorial branch), `ControlSwitch.swift`, `ControlDeckGroupHeader.swift`.
- `OpenBurnBarBuildGates.swift`, consumed by both `SettingsTab.visibleTabs` and `ControlKind.visibleKinds`.
- `SettingsBindings.swift` — extracted shared binding helpers: `costAlertThreshold(_:)` (the `Optional<Double>`↔`Bool` adapter), `conversationBackup(_:)` (the composite facade + consent-sheet presentation, **not** the flag stamp).
- Route wiring: `DashboardNavigationModel`, `DashboardView.detailView`, `routeWantsProviderSidebar` false branch, `quickAccessRoute(rawValue:)`, deck-strip icon, `DashboardSectionSwitcher` row, `CommandDeckPalette` entry, ⌘0.
- **Tiles (7):** Engine Room, Appearance, Pets, Text Expansion, Alerts & Digest (digest half shipping `.degraded`), Charts, Updates.
- New a11y ids (§10).

**Gates:** `xcodebuild` macOS Debug + Release; `ControlDeckLayoutTests` (round-trip, unknown-kind drop, new-kind append, span/visibility mutation, reset, within-group reorder); `CardRowPackerTests`; a Charts snapshot-parity assertion; `DashboardViewIntegrationTests` gains `routeWantsProviderSidebar(.controlDeck) == false` and a `quickAccessRoute("controlDeck")` round-trip; `BuildGateParityTests` asserts `visibleTabs` and `visibleKinds` agree under both `DISTRIBUTION_MAS` settings; a manual pass in Editorial skin + live backdrop + Reduce Transparency + Reduce Motion.

**Revert:** delete the route case and the `ControlDeck/` directory; the extracted packer and `SettingsBindings` are strict improvements and stay.

### PR 2 — The attention layer, the Overview band, and the prerequisite fixes

**Ships:** push discovery, and the repairs that make the deck's promises true.

- `ControlDeckSnapshot` (pure value type), `ControlAttention`, `ControlKind.attention(from:)` for every shipped kind.
- `ControlDeckAttentionRail` on the deck, `ControlDeckAttentionBand` on Overview — inserted **above** the `totalUsageSessionCount > 0` gate in `overviewRouteView`, capped at 3 with `"+N more →"`, collapsing to the green "All systems nominal" line.
- Attention count plumbed through the existing route-keyed `badge(for:)` map, not a parallel parameter.
- `SettingsEffectsObserver` — a small `@MainActor` service observing the domain stores and performing the write-time effects **once, for every surface**: `OpenBurnBarOperatingLayer.refreshControllerRuntime()` on controller-settings change (W-3). The digest (P1) is **out of scope** — `DailyDigestManager`'s cadence already reads its settings live on every tick, so routing it through the observer would duplicate that. Alerts & Digest has already dropped `.degraded`.
- P2, P3, P4, P5, P6, P7.
- **Tiles (+5):** AI Inbox, Memory, Quota Watch, Notifications, Model Router (with R-3 as click-through).

**Gates:** `ControlDeckAttentionTests` — pure fixtures for every blocking case (global expansion on with `AXIsProcessTrusted()` false; gateway on with 0 advertised; unauthenticated loopback; daemon unhealthy or version-mismatched; fleet memory kill switch; over-threshold spend; quota bucket >90%; inbox unavailable), asserting severity ordering and that the empty set produces the nominal line. `SettingsEffectsObserverTests` asserts the controller runtime refresh is called on change from **both** the deck binding and its settings-pane binding; the digest equivalent lives in `DailyDigestManagerTests`, which pins the re-arm behaviour directly. Deep-link scroll verified manually for all four repaired anchors. Overview band verified in all six `DashboardLayout` values **and** the zero-session welcome state.

**Revert:** the band and rail are additive; `SettingsEffectsObserver` and the anchor repairs are strict improvements and stay.

### PR 3 — Expensive tiles, Tier-2 expansion, and two-way discovery

- **Tier-2 expand-in-place**: chevron, span 1→2, fixed 248pt plate, the lifted stroke/shadow variant, re-pack under `.gentle`, `controlDeck.expansion.v1` persistence.
- **Tiles (+9):** The Wand, The Elder Wand, Memory MCP, Data & Privacy, Agent Control, Floo, Devices & Sync, Cloud, Quick Access — each with its cost discipline: MCP listener tied to expansion; device trust behind **Check devices**; `countUnsyncedSessionLogs()` behind an explicit refresh with an "as of" stamp; entitlement store read but never `.start()`ed; `PetCompanionFeature.runtime` never touched.
- Discovery: `ControlKind` indexed into `CommandDeckPalette`; the reciprocal Settings → deck links; `@AppStorage("dashboard.landingRoute")` + "Make this my home" + the General → Dashboard Defaults mirror.
- Type extractions this PR is allowed to make: `MacRemoteMCPClientStore` and `AIInboxSettingsModel` move out of Settings *view* files into `AgentLens/Services/` so a Dashboard route is not importing types declared inside `CloudStoreSettingsView+Support.swift`.

**Gates:** everything above, plus an instrumented check that a cold deck visit opens **zero** Firestore listeners and issues **zero** StoreKit calls; an assertion that Agent Control renders zero controls with a nil `computerUseRuntimeController`; a manual pass proving B-2 presents `SessionLogsCloudConsentSheet` and does not stamp `sessionLogCloudBackupConsentShown` directly; MAS-configuration build proving Agent Control and Updates are absent.

**Revert:** each tile is one `ControlKind` case plus one `ControlTileView` arm; `reconciled(_:)` guarantees removing a case leaves existing user layouts intact.

---

## 10. Accessibility

### Identifiers — `AgentLens/Support/AccessibilityIdentifiers.swift`

```swift
static let controlDeck              = "controlDeck.page"
static let controlDeckVitalsRail    = "controlDeck.vitalsRail"
static let controlDeckAttentionRail = "controlDeck.attentionRail"
static let controlDeckAttentionBand = "controlDeck.attentionBand"   // Overview
static let controlDeckFilter        = "controlDeck.filter"
static let controlDeckEditMenu      = "controlDeck.editMenu"
static func controlDeckTile(_ k: String) -> String        { "controlDeck.tile.\(k)" }
static func controlDeckToggle(_ k: String) -> String      { "controlDeck.tile.toggle.\(k)" }
static func controlDeckExpand(_ k: String) -> String      { "controlDeck.tile.expand.\(k)" }
static func controlDeckAttentionChip(_ k: String) -> String { "controlDeck.attention.\(k)" }
```

### Element structure

Each tile is `.accessibilityElement(children: .contain)` — **contain**, not `.ignore`. Charts cards ignore their children because they are read-only; deck tiles own controls, and VoiceOver must be able to reach and operate them.

Composed label: `"<title>. <state>. <headline>."`
Composed value on the control: `"On"` / `"Off"` / `"Locked, requires Cloud Pro"` / `"Needs Accessibility permission"`.
Hint on the body button: `"Opens <destination>."`

### Focus order

Page → header (title, filter capsule, overflow menu) → vitals pills, left to right → attention chips, left to right → then, per group in fixed order: group header → each tile in visual (row-major) order. **Within a tile:** eyebrow/body button → primary `ControlSwitch` → secondary controls, left to right → expand chevron. Reorder drag is exposed as `.accessibilityAction(named: "Move up")` / `"Move down"` / `"Make wide"` / `"Make compact"` / `"Hide tile"`, mirroring the `.contextMenu`, because drag-and-drop is not reachable by keyboard.

### What a VoiceOver user hears

| Tile / state | Announcement |
|---|---|
| Text Expansion, `.needsPermission` | *"Text Expansion. Needs Accessibility permission. 12 snippets, 9 enabled. Button, Grant Accessibility. Opens System Settings."* |
| Text Expansion, `.on` | *"Text Expansion. On. 12 snippets, 9 enabled. Expand in other Mac apps, On. Button."* |
| AI Inbox, `.on` | *"AI Inbox. On. 4 unread, 62 cents of 2 dollars today. Run the AI Inbox, On. Button."* |
| AI Inbox, `.unavailable` | *"AI Inbox. Unavailable. Daemon not running. Button, Retry."* |
| Agent Control, live session | *"Agent Control. Session active. Ask every step, 14 deny rules. Button, Panic halt. Stops the running session immediately."* |
| Agent Control, nil runtime | *"Agent Control. Unavailable. Runtime not started."* (no controls announced) |
| Memory, consent ungranted | *"Memory. Off. 7 memories waiting for review. Button, Turn on memory. Opens the memory consent sheet."* |
| Cloud, locked | *"Cloud. Locked, requires Cloud Pro. Free tier. Button, Unlock. Opens the upgrade sheet."* |
| Attention chip | *"Attention. Text Expansion needs Accessibility. Button. Scrolls to the Text Expansion tile."* |
| Nominal line | *"All systems nominal. 21 features healthy. Daemon 1.4.2. Button. Opens the Control Deck."* |

### Motion, transparency, contrast

Every animation passes `nil` under `@Environment(\.accessibilityReduceMotion)`, including the drop-target scale and the numeric content transition. `accessibilityReduceTransparency` is honoured inside the LiquidGlass adapters, which the deck calls exclusively. `liquidGlassTransparency`'s positive branch is clamped to 0 under reduce-transparency by the existing adapter — the deck adds nothing here and must not bypass it. Status is never conveyed by colour alone: every dot is paired with a text label in the status ladder, and every attention state carries its cause in words.

---

## 11. Non-goals and risks

### Non-goals

1. **The deck is not a Settings replacement.** Settings remains the searchable, copilot-addressable index of everything, and `SettingsActionRegistry` mutations flow through to the deck for free. Snippet CRUD, provider keys, scope-rule policy, device trust, the appearance matrix, and the Data Control Center stay single-homed.
2. **The deck does not become the default home.** `dashboard.landingRoute` defaults to `"overview"`. Overview stays the storytelling home; the deck is the operator home for anyone who opts in.
3. **`primarySections` and ⌘1–⌘8 are not touched.** Ever, in any PR.
4. **`ChartCardChrome` adoption is out of scope.** The deck copies the shipped `ChartCardView` recipe so it looks native on day one. If the team wants `.chartGlassCard()` + `ChartInk`, Charts and the deck flip together in one dedicated PR, and the per-group accent then survives only in instrument ink. That is Alberto's call, not a side effect of this feature.
5. **No new persistence layer.** Everything scalar binds the existing `SettingsManager` facade over `@Observable` domain stores writing through the 100ms-debounced `SettingsPersistenceCoordinator`.
6. **No mobile/iOS port in these three PRs.**

### Risks, with mitigations and the tripwire that would falsify them

| Risk | Mitigation | Falsified if |
|---|---|---|
| **21 tiles read as a bag of tinted slabs** — the failure mode `ChartCardChrome`'s own header names | six accents assigned per *group*; strict 0.04/0.08 wash and 0.22 hairline; colour otherwise only in instrument ink; six labelled bands; 15 visible by default; one-click "Needs you" filter | a design review says the page is noisy at 4 columns — escalation is one neutral plate with accent surviving only in the dot and glyph, which is a one-file change to `ControlTileChrome` |
| **Two homes for one setting drift** | every scalar binds the same facade → same store → same coordinator; behaviour-around-the-write (`conversationBackupEnabled` composite, `PetCompanionFeature.toggleCompanion()`, the AI Inbox daemon round-trip, the `Optional<Double>` adapter) is **extracted into `SettingsBindings` in PR1**, not copied; analytics reuse each pane's exact `setting_key` plus a `surface` dimension | a settings pane and a tile disagree after a write — the extraction is the structural answer, and `SettingsEffectsObserverTests` is the regression gate |
| **A live surface costs money and CPU** | scalar reads are free; MCP listener tied to Tier-2 expansion; device trust behind a button; backup counts behind explicit refresh; entitlement store read but never started; `PetCompanionFeature.runtime` never touched; the deck never re-implements permission probes | the PR3 instrumented check sees a listener or a StoreKit call on a cold visit |
| **Discovery still fails** | seven entry points, two of which are push (Overview band, section-switcher badge) and one of which is search (`ControlKind` in ⌘K), plus the reciprocal Settings link | usage shows the route unopened — cheap escalation is flipping `dashboard.landingRoute`'s default for **new installs only**, not reshuffling shortcuts |
| **Scope creep back into a mega-PR** | three PRs, hard tile allocation, each with its own gates; PR1 ships a working page with seven tiles and no new async | any PR grows a tile from a later stage — push it back rather than widening |
| **Genuinely open question: The Wand's headline** | `MissionsLaneView` reads mission state through `MissionConsoleWindowController.bind(to: operatingLayer)`; the exact observable for "N workers running" is **not yet confirmed** | it is confirmed before PR3, or The Wand ships with the fan-out capsule and a `"3 of 8 lanes"` entitlement headline only |
| **Repairing existing bugs widens PR2** | P1 and the controller latency are fixed once at the service level so both surfaces inherit; the four anchor repairs are one-file each | a repair turns out to need a daemon protocol change — then it moves to its own PR and the dependent tile ships `.degraded`, which is honest and already specified |

### The one thing that must not be compromised

If review pressure forces a cut, cut tiles — never cut the exclusion list in §5, the `runtimeContext` requirement on Agent Control, or the consent sheet on B-2. A deck that ships nine tiles and cannot grant trust from any of them is a success. A deck that ships twenty-one and has one unguarded switch is not.

---

## 12. Corrections to the bake-off proposals

Recorded so the next engineer does not re-derive them.

- **D1 — `SwitchToggleStyle`.** All three proposals specified system switches on glass plates. Verified absent from `AgentLens/Views/Dashboard` and `AgentLens/Views/Charts`; the only `toggleStyle` calls there are `.checkbox` (`MacWandComposerSheet.swift:118`, `Quota/SubscriptionCard.swift:440`). Replaced by `ControlSwitch` (§6.3).
- **D2 — accent inflation and the `warning`/`amber` collision.** `DesignSystem.swift:20` amber = `F28C38`/`FFA800`; `:54` warning = `C47800`/`FFA800`. Identical in dark. `warning` is now reserved for attention only (§6.2).
- **D3 — ragged rows.** `ChartCardView.swift:44` pins the chart body to `.frame(height: 150)`. Deck tiles get fixed 108/216pt content heights (§6.5).
- **D4 — the gateway toggle.** `GatewaySettings.swift:12-14` persists only; sole reader `OpenBurnBarDaemonManager+Lifecycle.swift:452`. Click-through until an observer lands (R-3).
- **D5 — the digest fix location.** Putting `scheduleDigest` in the tile leaves `AlertsSettingsView`'s `.onChange` firing analytics only. Fixed at the service level (§9 PR2).
- **D6 — the cloud-backup consent bypass.** `sessionLogCloudBackupConsentShown` is read at `DashboardView.swift:634` and `DashboardConsentCoordinator.swift:24,64` to decide whether to present `SessionLogsCloudConsentSheet`. Stamping it from a tile records consent the user never saw. B-2 presents the real sheet.
- **D7 — MCP store observability.** `MacRemoteMCPClientStore` is `ObservableObject` with `@Published` (`CloudStoreSettingsView+Support.swift:784-785`). It cannot be a stored property of an `@Observable` model — observation silently stops after the first render. Hold it as `@StateObject` inside the Memory MCP tile's expanded body, whose lifetime already matches `startListening()`/`stopListening()`.
- **D8 — grid reuse.** `ChartsReorderableGrid` is hard-typed to `ChartsPageLayout` / `ChartsSnapshot` / `ChartKind` and constructs `ChartCardView` at `:44`. "Reused verbatim" was false in all three proposals. PR1 extracts and refactors Charts onto the extraction, and budgets it.
- **D9 — `panicHalt` is a no-op by default.** `public var panicHalt: () -> Void = {}` (`ComputerUseSessionPanel.swift:419`); real binding only at `ComputerUseRuntimeController.swift:334`. The settings fallback at `ComputerUseSettingsView.swift:806` inserts an audit row and halts nothing. A-1 requires the runtime controller.
- **D10 — the section switcher.** `primarySections` has three call sites: `DashboardView.swift:716` (⌘1–⌘8), `CommandDeckPalette.swift:102-104`, and `DashboardSectionSwitcher.swift:41`. Two of three proposals patched only the palette. All three are handled (§3.3).
- **D11 — `MercuryConsentStore` injection.** The runtime instance is a local `let` inside `startMercuryServices()` (`OpenBurnBarStartupRecovery.swift:659`) and is **not** on `OpenBurnBarRuntimeContext`. PR3 promotes it to the runtime context; F-2 must not construct a third `@StateObject`.
- **D12 — the Overview band and the welcome state.** `overviewRouteView` is `if dataStore.totalUsageSessionCount > 0 { switch layout } else { welcome }`. "Above the layout switch" places the band inside the has-data branch. It goes above the gate (§4.4).
- **D13 — cold start.** No proposal enumerated its default visible set. §7 does, plus the welcome tile.
