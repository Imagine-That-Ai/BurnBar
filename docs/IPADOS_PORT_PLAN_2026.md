# iPadOS App Port Plan — OpenBurnBar

**Date:** 2026-05-02  
**Scope:** Full iPadOS feature parity with macOS AgentLens (cloud-sync companion)  
**Target:** iPadOS 17.0+ (same as existing mobile target)  
**Architecture:** Cloud-first read-only companion; Mac pushes, iPad reads.

---

## 1. Executive Summary

The iPad app is a **first-class dashboard**, not a dumbed-down companion. It opens directly into a `NavigationSplitView` dashboard with the same routes, charts, lanes, and deep-drill views as macOS. There is no menu bar; the app is a regular foreground `WindowGroup` app. All data comes from Firebase Firestore (already published by the Mac). No local log parsing, no daemon, no CLI bridge.

**What ships:** Dashboard (Overview, Providers, Models, Projects, Missions, Activity, Session Logs, Settings), full-screen Hermes chat, onboarding wizard, account switcher, Home Screen widget, Live Activity, daily digest notifications.

**What does not ship:** Menu bar popover, local daemon, CLI bridge, file-system scanning, Database Workspace, local FTS5/vector search.

---

## 2. Architecture Decision Records (ADRs)

### ADR-1: No Local Database on iPad (Option A — Pure Firestore)

**Decision:** The iPad app reads exclusively from Firestore via snapshot listeners. No GRDB, no SQLite, no FTS5, no vector index.

**Rationale:**
- Sandbox prevents filesystem log scanning; local DB would only cache Firestore data anyway.
- Firestore SDK provides offline disk persistence automatically (`Persistence.enabled = true`).
- Adding GRDB would introduce ~15MB binary bloat, schema drift risk, and migration complexity for zero functional gain.
- If offline mode becomes critical later, Firestore's built-in cache is sufficient for 90% of use cases.

**Consequences:**
- All search is client-side filtering on in-memory arrays (sufficient for session logs up to a few thousand records).
- No semantic/vector search on iPad.
- Data freshness depends on network; Firestore offline cache handles brief disconnects.

### ADR-2: Hermes Chat via HTTP API Only (No CLI Bridge)

**Decision:** Chat on iPad supports Hermes mode only (HTTP SSE to `localhost:8642` or cloud endpoint). No Local Index / CLI bridge.

**Rationale:**
- iPad cannot spawn `codex`/`claude` subprocesses (`Process` API is unavailable).
- Hermes already exposes an OpenAI-compatible `/v1/chat/completions` endpoint with SSE streaming.
- On same Wi-Fi, iPad can reach `mac-hostname.local:8642` via Bonjour.
- Fallback: proxy through a cloud Cloud Function if LAN is unreachable.

**Consequences:**
- Chat mode toggle (Local Index ↔ Hermes) is hidden on iPad.
- Tool cards, mercury styling, and thinking animation are identical to macOS.
- Multi-turn memory works via Firestore `chat_threads` collection (already synced).

### ADR-3: Client-Side Search with Firestore Pagination (No Full-Text Backend)

**Decision:** Session log search filters the already-downloaded `ConversationRecord` array in memory. No Cloud Functions full-text backend for MVP.

**Rationale:**
- Firestore has no native full-text search; prefix queries are limited.
- Algolia/Typesense would add a third-party dependency and cost.
- A typical user has <5,000 sessions; client-side `filter` on title + body is instantaneous.
- The macOS FTS5 index is for local file parsing; iPad has no local files to index.

**Consequences:**
- Search only covers already-loaded pages. User must scroll to load more before searching deeper history.
- No semantic "find similar sessions" capability.
- Future: add a Cloud Function using Firestore vector search (2025+ feature) if scale demands it.

### ADR-4: NavigationSplitView as Primary chrome (Replace Tab Bar on iPad)

**Decision:** On iPad, replace `RootTabView` with a `NavigationSplitView` root. iPhone keeps the existing tab bar.

**Rationale:**
- `NavigationSplitView` is the canonical iPad replacement for macOS window management.
- It provides a persistent sidebar with the same routes as macOS Dashboard + Settings.
- macOS already uses `NavigationSplitView` for both Dashboard and Settings; porting is mechanical.
- iPhone retains `TabView` because `NavigationSplitView` collapses poorly on compact width without extra work.

**Consequences:**
- iPad and iPhone have divergent top-level navigation (acceptable; they're different size classes).
- `RootTabView` remains for iPhone; a new `RootNavigationView` is added for iPad.
- Both share the same child views (Dashboard, Quota, Activity, etc.).


---

## 3. File-Level Implementation Plan

### 3.1 New Files (iPad-First)

| File | Path | Responsibility |
|------|------|----------------|
| `RootNavigationView.swift` | `OpenBurnBarMobile/Views/` | `NavigationSplitView` root for iPad. Sidebar routes + detail pane. Replaces `RootTabView` on iPad only. |
| `DashboardSidebar.swift` | `OpenBurnBarMobile/Views/Dashboard/` | Sidebar list with same routes as macOS: Overview, Agents, Models, Projects, Missions, Activity, Session Logs, Settings. |
| `DashboardDetailView.swift` | `OpenBurnBarMobile/Views/Dashboard/` | Route-based detail content switch. Mirrors `DashboardDetailView` macOS pattern. |
| `DashboardOverviewView.swift` | `OpenBurnBarMobile/Views/Dashboard/` | Hero metrics row + narrative card + provider/model lanes + recent sessions. Reads from `DashboardStore`. |
| `ProviderDashboardView.swift` | `OpenBurnBarMobile/Views/Dashboard/` | Deep dive into single provider. Quota panel, token breakdown chart, daily trend chart, model stack, session ledger. |
| `ModelDashboardView.swift` | `OpenBurnBarMobile/Views/Dashboard/` | Deep dive into single model across providers. Same pattern as Provider Dashboard. |
| `SessionLogsView.swift` | `OpenBurnBarMobile/Views/Dashboard/` | Two-column `NavigationSplitView`: left = searchable/grouped list, right = `SessionDetailView`. |
| `ProjectsView.swift` | `OpenBurnBarMobile/Views/Dashboard/` | List → hub drill-in. Read-only view of missions/questions/followups from Firestore. |
| `MissionsLaneView.swift` | `OpenBurnBarMobile/Views/Dashboard/` | Read-only mission control lane. Lists active missions, questions, followups. |
| `ChatView.swift` | `OpenBurnBarMobile/Views/Chat/` | Full-screen chat view (not floating). Wraps `ChatMessageView`, `ChatInputRow`, `HermesThinkingView`, `HermesToolCard`. |
| `ChatMessageView.swift` | `OpenBurnBarMobile/Views/Chat/` | Port from macOS. Bubbles, badges, mercury gradient strokes. |
| `HermesToolCard.swift` | `OpenBurnBarMobile/Views/Chat/` | Port from macOS. Collapsible tool cards with mercury gradient stroke. |
| `HermesThinkingView.swift` | `OpenBurnBarMobile/Views/Chat/` | Port from macOS. Mercury droplet pooling animation. |
| `MercuryShimmerModifier.swift` | `OpenBurnBarMobile/Views/Chat/` | Port from macOS. Shimmer animation for mercury gradient borders. |
| `ChatInputRow.swift` | `OpenBurnBarMobile/Views/Chat/` | Port from macOS. Text input + send button + backend mode indicator. |
| `SettingsView.swift` | `OpenBurnBarMobile/Views/Settings/` | `NavigationSplitView` with 8 tabs. Hides macOS-only tabs (Daemon). |
| `GeneralSettingsView.swift` | `OpenBurnBarMobile/Views/Settings/` | Port from macOS. Appearance, usage display, refresh interval, auto-scan (hidden), indexing (hidden), daily digest, onboarding reset. |
| `AccountSettingsView.swift` | `OpenBurnBarMobile/Views/Settings/` | Port from macOS. Firebase auth, anonymous mode, cloud sync, delete account. Reuses mobile auth. |
| `ProvidersSettingsView.swift` | `OpenBurnBarMobile/Views/Settings/` | Port from macOS. Provider connections via callable functions. No local path config. |
| `AlertsSettingsView.swift` | `OpenBurnBarMobile/Views/Settings/` | Port from macOS. Cost thresholds, daily budget, token alerts. |
| `NotificationsSettingsView.swift` | `OpenBurnBarMobile/Views/Settings/` | Port from macOS. `UNUserNotificationCenter` settings, digest time. |
| `DevicesAndSyncSettingsView.swift` | `OpenBurnBarMobile/Views/Settings/` | Port from macOS. Connected devices, sync status. Reuses `DevicesStore`. |
| `AccountSwitcherSettingsView.swift` | `OpenBurnBarMobile/Views/Settings/` | Port from macOS. Multi-account profile management. |
| `OnboardingWizardView.swift` | `OpenBurnBarMobile/Views/Onboarding/` | Port from macOS. Same 6-step flow. Skip `.scan` step (no log access). Focus on cloud connect + Hermes setup. |
| `GlassCard.swift` | `OpenBurnBarMobile/Views/Components/` | Port from macOS. `.ultraThinMaterial` + gradient stroke. Uses `MobileTheme` colors. |
| `StatCard.swift` | `OpenBurnBarMobile/Views/Components/` | Port from macOS. Hero metric card with accent gradient. |
| `MiniSparkline.swift` | `OpenBurnBarMobile/Views/Components/` | Port from macOS. SwiftUI Charts line mark. Already pure SwiftUI. |
| `ProviderLogoView.swift` | `OpenBurnBarMobile/Views/Components/` | Port from macOS. Asset + SF Symbol fallback. |
| `NarrativeCardView.swift` | `OpenBurnBarMobile/Views/Components/` | Port from macOS. AI insight headline card. |
| `DashboardActionGlyphs.swift` | `OpenBurnBarMobile/Views/Components/` | Port from macOS. Toolbar action icons (refresh, scan, recount, settings). |
| `DashboardNavigationModel.swift` | `OpenBurnBarMobile/Models/` | Port from macOS. `@Observable` route history + view mode. Already platform-agnostic. |
| `ChatStore.swift` | `OpenBurnBarMobile/Models/` | NEW. Manages Hermes chat state: messages, streaming, tool cards, history. Reads/writes Firestore `chat_threads`. |
| `SessionLogStore.swift` | `OpenBurnBarMobile/Models/` | NEW. Paginated + searchable session logs from Firestore `conversations` collection. |
| `ProjectStore.swift` | `OpenBurnBarMobile/Models/` | NEW. Read-only project/mission/followup data from Firestore `projects` + `missions` collections. |
| `HermesChatClient.swift` | `OpenBurnBarMobile/Services/` | NEW. HTTP client for Hermes `/v1/chat/completions`. SSE streaming, timeout, retry. |
| `BonjourDiscovery.swift` | `OpenBurnBarMobile/Services/` | NEW. `NetServiceBrowser` to discover `mac-hostname.local:8642` on LAN. |
| `DailyDigestManager.swift` | `OpenBurnBarMobile/Services/` | NEW. `UNUserNotificationCenter` local notification at configurable hour. Reads `usage_rollups` for summary. |


### 3.2 Modified Files

| File | Change |
|------|--------|
| `OpenBurnBarMobileApp.swift` | Detect iPad vs iPhone. iPad → `RootNavigationView`. iPhone → keep `RootTabView`. |
| `AuthGateView.swift` | Inject new stores (`ChatStore`, `SessionLogStore`, `ProjectStore`) into the auth-gate dependency tree. |
| `RootTabView.swift` | Keep for iPhone. Add conditional `#if os(iOS)` size-class check if needed. |
| `DashboardView.swift` | Expand from single-column ScrollView to multi-pane layout on iPad. Reuse `HeroCard`, `PeriodCard` on iPhone; use `StatCard` + lanes on iPad. |
| `MobileTheme.swift` | **CRITICAL:** Add all missing tokens from macOS `DesignSystem.swift`: `hermesMercury`, `hermesAureate`, `mercuryGradient`, `mercuryShimmer` animation, `glassCard` material pattern, provider chart palettes, model color hashing. Add `MobileTheme.Animation` namespace. |
| `Package.swift` (Core) | No changes needed. Already supports iOS 17+. |

### 3.3 Ported from macOS (Copy + Adapt)

| macOS Source | iPad Destination | Adaptation Notes |
|--------------|------------------|------------------|
| `AgentLens/Theme/DesignSystem.swift` | Merge into `MobileTheme.swift` | Replace `NSColor` references with `UIColor`. Keep all tokens. |
| `AgentLens/Theme/ColorAdaptive.swift` | Add `#if canImport(UIKit)` branch | Already has `UIColor` init; verify dynamic provider works. |
| `AgentLens/Theme/ProviderTheme.swift` | Move to `OpenBurnBarMobile/Theme/` | Pure SwiftUI; no macOS dependencies. |
| `AgentLens/Views/Dashboard/DashboardSidebar.swift` | `OpenBurnBarMobile/Views/Dashboard/DashboardSidebar.swift` | Remove `AppKit` import. Replace `NSWorkspace.open()` with `UIApplication.shared.open()`. Remove cursor extension button (macOS-only). |
| `AgentLens/Views/Dashboard/DashboardOverviewView.swift` | `OpenBurnBarMobile/Views/Dashboard/DashboardOverviewView.swift` | Replace `DataStoreCoordinator` with `DashboardStore`. Remove local-data dependencies. |
| `AgentLens/Views/Dashboard/ProviderDashboardView.swift` | `OpenBurnBarMobile/Views/Dashboard/ProviderDashboardView.swift` | Replace local data with Firestore reads. Use `QuotaStore` for quota panel. |
| `AgentLens/Views/Dashboard/ModelDashboardView.swift` | `OpenBurnBarMobile/Views/Dashboard/ModelDashboardView.swift` | Same as Provider Dashboard. |
| `AgentLens/Views/SessionLogs/SessionLogsView.swift` | `OpenBurnBarMobile/Views/Dashboard/SessionLogsView.swift` | Remove local/iCloud data source toggle. Use `SessionLogStore` (Firestore). Remove FTS5 retrieval health banner. Keep search + group mode + device filter. |
| `AgentLens/Views/Dashboard/ProjectsView.swift` | `OpenBurnBarMobile/Views/Dashboard/ProjectsView.swift` | Remove daemon execution buttons. Read-only view. Use `ProjectStore`. |
| `AgentLens/Views/Chat/ChatMessageView.swift` | `OpenBurnBarMobile/Views/Chat/ChatMessageView.swift` | Remove `AppKit` import. Pure SwiftUI. |
| `AgentLens/Views/Chat/HermesToolCard.swift` | `OpenBurnBarMobile/Views/Chat/HermesToolCard.swift` | Pure SwiftUI. |
| `AgentLens/Views/Chat/HermesThinkingView.swift` | `OpenBurnBarMobile/Views/Chat/HermesThinkingView.swift` | Pure SwiftUI. |
| `AgentLens/Views/Chat/MercuryShimmerModifier.swift` | `OpenBurnBarMobile/Views/Chat/MercuryShimmerModifier.swift` | Pure SwiftUI. |
| `AgentLens/Views/Chat/ChatInputRow.swift` | `OpenBurnBarMobile/Views/Chat/ChatInputRow.swift` | Remove macOS-specific toolbar items. |
| `AgentLens/Views/Settings/SettingsView.swift` | `OpenBurnBarMobile/Views/Settings/SettingsView.swift` | Remove `.frame(minWidth:…)` (macOS window sizing). Hide `.daemon` tab. |
| `AgentLens/Views/Settings/GeneralSettingsView.swift` | `OpenBurnBarMobile/Views/Settings/GeneralSettingsView.swift` | Hide auto-scan, indexing, daemon-related toggles. |
| `AgentLens/Views/Settings/AccountSettingsView.swift` | `OpenBurnBarMobile/Views/Settings/AccountSettingsView.swift` | Replace `NSWorkspace.open()` with `UIApplication.shared.open()`. |
| `AgentLens/Views/Settings/ProvidersSettingsView.swift` | `OpenBurnBarMobile/Views/Settings/ProvidersSettingsView.swift` | Remove local path pickers. Keep provider enable/disable + plan tier. |
| `AgentLens/Views/Settings/Alerts...` etc. | `OpenBurnBarMobile/Views/Settings/Alerts...` | Port all remaining settings tabs. |
| `AgentLens/Views/Onboarding/OnboardingWizardView.swift` | `OpenBurnBarMobile/Views/Onboarding/OnboardingWizardView.swift` | Skip `.scan` step. Remove `aggregator` dependency. |
| `AgentLens/Views/Components/GlassCard.swift` | `OpenBurnBarMobile/Views/Components/GlassCard.swift` | Search for this — if it doesn't exist, build from `DesignSystem` spec. |
| `AgentLens/Views/Components/StatCard.swift` | `OpenBurnBarMobile/Views/Components/StatCard.swift` | Search for this — if it doesn't exist, build from `DesignSystem` spec. |
| `AgentLens/Views/Components/MiniSparkline.swift` | `OpenBurnBarMobile/Views/Components/MiniSparkline.swift` | Already pure SwiftUI + Charts. |
| `AgentLens/Views/Components/ProviderLogoView.swift` | `OpenBurnBarMobile/Views/Components/ProviderLogoView.swift` | Pure SwiftUI. |
| `AgentLens/Views/Components/NarrativeCardView.swift` | `OpenBurnBarMobile/Views/Components/NarrativeCardView.swift` | Replace `DataStore` with `DashboardStore`. |
| `AgentLens/Views/Popover/PopoverQuickSwitchView.swift` | `OpenBurnBarMobile/Views/Settings/AccountSwitcherSheet.swift` | Present as `.sheet` instead of popover. |

### 3.4 Skipped (macOS-Only)

| macOS File | Reason |
|------------|--------|
| `MenuBarPopoverView.swift` | No menu bar on iPad. Replaced by app dashboard. |
| `HermesPopoverStrip.swift` | Replaced by full-screen `ChatView`. |
| `DatabaseWorkspaceView.swift` | Local DB exploration is macOS-only. |
| `CLIBridge/*.swift` | iPad cannot spawn subprocesses. |
| `OpenBurnBarDaemon/*.swift` | No daemon on iPad. |
| `LogParser/*.swift` | No filesystem log access. |
| `DataStore/*.swift` (local SQLite) | No local DB on iPad. |
| `CursorConnector/*.swift` (local router) | Local OpenAI-shaped router requires macOS network stack. |
| `WindowManager.swift` | `NSWindow` is macOS-only. Use `NavigationSplitView`. |

---

## 4. Navigation Routing

### 4.1 Dashboard Route Enum (Reused from macOS)

```swift
enum DashboardMainRoute: Hashable {
    case overview
    case provider(AgentProvider)
    case model(String)
    case sessionLogs
    case projects
    case missions
    case settings(SettingsTab)
    case chat
}
```

### 4.2 Settings Tab Enum (Reused from macOS, minus Daemon)

```swift
enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case account
    case providers
    case alerts
    case notifications
    case devicesAndSync
    case switcher
    
    // `.daemon` excluded on iPad
}
```

### 4.3 Navigation Stack Drill-Ins

```swift
enum DrillInRoute: Hashable {
    case providerDetail(AgentProvider)
    case modelDetail(String)
    case projectDetail(String)
    case sessionDetail(ConversationRecord)
    case quotaDetail(ProviderQuotaSnapshot)
}
```

---

## 5. Data Flow Diagram

```
┌─────────────────┐     Firestore      ┌─────────────────┐
│   macOS App     │ ─────────────────→ │   iPadOS App    │
│  (AgentLens)    │  usage_rollups     │ (reads only)    │
│                 │  quota_snapshots   │                 │
│  Local SQLite   │  conversations     │  Firebase SDK   │
│  + GRDB + FTS5  │  chat_threads      │  + Firestore    │
│  + Daemon       │  projects          │  listeners      │
│  + Log Parsers  │  missions          │                 │
│  + CLI Bridge   │  devices           │  Hermes chat    │
│  + Hermes       │  provider_connections│ via HTTP API   │
│                 │                   │                 │
│  MacCloudPublisher                │                 │
│  (pushes every 30s)              │                 │
└─────────────────┘                   └─────────────────┘
```

**iPad read paths:**
- `DashboardStore` → `users/{uid}/usage_rollups/{window}`
- `QuotaStore` → `users/{uid}/quota_snapshots`
- `ActivityStore` → `users/{uid}/conversations` (paginated)
- `SessionLogStore` → `users/{uid}/conversations` (paginated + searchable)
- `ProjectStore` → `users/{uid}/projects`, `users/{uid}/missions`
- `ChatStore` → `users/{uid}/chat_threads/{threadId}`
- `DevicesStore` → `users/{uid}/devices`
- `ProviderSummaryStore` → `users/{uid}/provider_connections`

---

## 6. Firestore Schema Verification

All required collections already exist and are populated by the Mac:

| Collection | Document Shape | Mac Publisher | iPad Consumer |
|------------|---------------|---------------|---------------|
| `users/{uid}/usage_rollups/{window}` | `UsageRollupDoc` | `UsageSyncService` | `DashboardStore` ✅ |
| `users/{uid}/quota_snapshots/{provider}` | `ProviderQuotaSnapshot` | `QuotaSnapshotSyncService` | `QuotaStore` ✅ |
| `users/{uid}/conversations/{id}` | `ConversationRecord` | `ConversationSyncService` | `ActivityStore`, `SessionLogStore` ✅ |
| `users/{uid}/chat_threads/{id}` | `ChatThreadDoc` | `ChatThreadSyncService` | `ChatStore` ✅ |
| `users/{uid}/projects/{id}` | `BurnBarReviewProjectSnapshot` | `CollaborationSyncService` | `ProjectStore` ✅ |
| `users/{uid}/missions/{id}` | `BurnBarMissionDoc` | `CollaborationSyncService` | `ProjectStore` ✅ |
| `users/{uid}/devices/{id}` | `CloudDevice` | `DeviceStore` | `DevicesStore` ✅ |
| `users/{uid}/provider_connections/{id}` | `ProviderConnection` | Mac settings | `ProviderSummaryStore` ✅ |
| `users/{uid}/cloud_profile/default` | `CloudProfile` | `AccountManager` | `AuthStore` ✅ |

**No schema changes required.** The iPad app is a pure consumer of existing Mac-published data.

---

## 7. UI Mockup Descriptions

### 7.1 Dashboard Overview (Primary Screen)

**Layout:** `NavigationSplitView` with 280pt sidebar + detail pane.

**Sidebar:**
- App logo + name at top
- Navigation sections: Overview, Agents (expandable list of active providers), Models (expandable list), Projects, Missions, Activity, Session Logs, Settings
- Selected state: `MobileTheme.Colors.accent` background pill
- Bottom: sync health indicator + last refresh time

**Detail — Overview:**
- **Hero row:** 3 `StatCard`s in an `HStack` — Total Cost (whimsy accent), Tokens (ember), Sessions (amber). Each card has a mini sparkline.
- **Narrative card:** Full-width `GlassCard` with AI-generated insight headline (`NarrativeCardView`).
- **Lanes row:** Two-column `HStack`:
  - Left: `DashboardProviderLaneView` (ranked provider cards with cost + sparkline)
  - Right: `DashboardModelLaneView` + `DashboardActivityLaneView` (recent sessions)
- **Recent sessions:** Horizontal scroll of last 5 sessions with provider badge + cost pill

**Interaction:**
- Tap provider in lane → push `ProviderDashboardView` via `NavigationStack`
- Tap model in lane → push `ModelDashboardView`
- Tap session → push `SessionDetailView`
- Pull-to-refresh triggers `DashboardStore.refresh()`

### 7.2 Session Logs (Two-Pane Search)

**Layout:** Two-column `NavigationSplitView` (400pt list + detail).

**Left pane — Search & List:**
- Search bar at top (`searchable(text:placement:)`)
- Filter pills: Source (All / Provider / Assistant), Group mode (Time / Provider / Project), Device filter (if multi-device)
- Grouped `LazyVStack` with section headers
- Each row: Provider badge + session title + cost pill + timestamp
- Tap row → select conversation, show detail in right pane

**Right pane — Detail:**
- Reuses existing `SessionDetailView` (already in mobile)
- Header: Provider badge + model name + total cost + token breakdown
- Body: Markdown-rendered transcript
- Footer: device name + sync status

**Interaction:**
- Search filters client-side on already-loaded `ConversationRecord`s
- Group mode toggle restructures sections
- Device filter bar appears only when `knownDevices.count > 1`

### 7.3 Chat (Full-Screen Hermes)

**Layout:** Full-screen modal (`.sheet`) or push into `NavigationStack`.

**Header:**
- Back button + "Hermes" title + caduceus glyph
- Connection status dot (green = reachable, amber = connecting, red = offline)
- Clear history button

**Message list:**
- `ScrollViewReader` for auto-scroll to bottom
- User bubbles: right-aligned, whimsy stroke, `ChatBubbleStyle.userShape()`
- Hermes bubbles: left-aligned, mercury gradient stroke, `ModelProviderLogoView`
- Tool cards: inline between messages, collapsible, mercury gradient stroke
- Thinking state: 3 mercury droplets with pooling animation

**Input bar:**
- Text field with "Ask Hermes..." placeholder
- Send button with mercury gradient
- Mercury shimmer border on the input field when focused

**Interaction:**
- Tap tool card → expand/collapse detail
- Long-press message → copy text
- Keyboard shortcut `⌘↵` to send (external keyboard)

### 7.4 Settings (NavigationSplitView)

**Layout:** `NavigationSplitView` with 220pt sidebar + detail pane (same as macOS).

**Sidebar:**
- 7 tabs (General, Account, Providers, Alerts, Notifications, Devices & Sync, Account Switcher)
- Each tab has a colored icon + label
- Selected tab highlighted with accent color pill

**Detail panes:**
- **General:** Appearance picker (light/dark/system), usage display mode, refresh interval slider, daily digest toggle + time picker, onboarding reset button
- **Account:** Profile card (photo, name, email), sign-out, delete account, anonymous mode toggle
- **Providers:** List of providers with enable toggle + plan tier picker. No local paths. Add via callable function.
- **Alerts:** Cost threshold slider, daily budget field, token alert toggle
- **Notifications:** Enable/disable digest, time picker, preview
- **Devices & Sync:** Device list with trust pills, sync status, iCloud mirroring toggle
- **Account Switcher:** Profile list, add new, switch action

**Interaction:**
- Tap sidebar item → detail pane updates
- `.sheet` for account switcher profile form
- `.alert` for destructive actions (delete account, revoke device)

### 7.5 Projects Hub

**Layout:** List → drill-in via `NavigationStack`.

**List:**
- Each row: Project name + slug + total cost + session count + attention badge (questions/missions/followups)
- Sort by: recent activity, cost, name
- Filter by: provider, mission status

**Hub (drill-in):**
- Header: Project name + registered status + automation mode
- **Questions section:** Expandable list of pending questions
- **Missions section:** Active missions with status badges
- **Followups section:** Open followups with assignee + due date
- **Reviews section:** Daily/weekly review history + re-run buttons (read-only on iPad)
- **Usage metrics:** Mini chart of project cost over time

**Interaction:**
- Tap project row → push hub
- Tap question/mission/followup → push detail
- Re-run review buttons disabled (no daemon on iPad) with tooltip: "Run reviews on your Mac"

---

## 8. Dependency List

### 8.1 Existing Dependencies (No Changes)

| Package | Version | Usage |
|---------|---------|-------|
| `OpenBurnBarCore` | local | Shared models, contracts, formatting |
| `Firebase` (firebase-ios-sdk) | 11.0.0+ | Auth, Firestore, Functions, App Check |
| `GoogleSignIn` | 8.0.0+ | Google auth |
| `Sentry` | 8.0.0+ | Crash reporting |

### 8.2 New Dependencies

| Package / Framework | Source | Usage |
|---------------------|--------|-------|


| `Network` (Bonjour) | Apple framework | `NetServiceBrowser` for Hermes LAN discovery |
| `UserNotifications` | Apple framework | Daily digest local notifications |

**No new Swift packages needed.** All new capabilities use Apple first-party frameworks.

### 8.3 project.yml Changes

```yaml
targets:
  OpenBurnBarMobile:
    settings:
      base:
        TARGETED_DEVICE_FAMILY: "1,2"  # Already set
        SUPPORTS_MACCATALYST: NO
        SUPPORTS_MAC_DESIGNED_FOR_IPHONE_IPAD: NO

```

---

## 9. Migration Plan

### 9.1 iPhone Compatibility

The existing iPhone app **must not break**. Strategy:

1. **Keep `RootTabView`** for iPhone. Do not delete it.
2. **Add `RootNavigationView`** for iPad. Branch at `AuthGateView`:
   ```swift
   @ViewBuilder
   var mainView: some View {
       #if os(iOS)
       if UIDevice.current.userInterfaceIdiom == .pad {
           RootNavigationView(...)
       } else {
           RootTabView(...)
       }
       #endif
   }
   ```
3. **Share child views.** Both `RootTabView` and `RootNavigationView` embed the same `DashboardView`, `QuotaView`, `ActivityView`, `AccountView` components.
4. **Responsive layouts.** Use `@Environment(\.horizontalSizeClass)` inside shared views to branch between compact (iPhone) and regular (iPad) layouts.

### 9.2 Incremental Rollout

```
Week 1-2: Theme + Components
  - Expand MobileTheme.swift with all DesignSystem tokens
  - Port GlassCard, StatCard, MiniSparkline, ProviderLogoView, NarrativeCardView
  - Verify iPhone tab bar still works

Week 3-4: Dashboard Shell
  - Build RootNavigationView (iPad only)
  - Build DashboardSidebar + DashboardDetailView
  - Build DashboardOverviewView with hero + lanes
  - Connect DashboardStore (already works)

Week 5-6: Deep Drill Views
  - ProviderDashboardView, ModelDashboardView
  - SessionLogsView (two-pane)
  - ProjectsView + ProjectStore

Week 7-8: Settings + Onboarding
  - Port all 7 settings tabs (hide Daemon)
  - Port OnboardingWizardView (skip scan)

Week 9-10: Chat
  - HermesChatClient service
  - ChatView + message bubbles + tool cards
  - Bonjour discovery

Week 11-12: Notifications
  - DailyDigestManager

Week 13-14: Polish + Testing
  - iPad-specific layout tests (landscape, portrait, Stage Manager)
  - VoiceOver audit
  - Dynamic Type audit
  - UI tests for onboarding → auth → dashboard → settings flow
```

---

## 10. Risk Assessment

| # | Risk | Likelihood | Impact | Mitigation |
|---|------|------------|--------|------------|
| 1 | **Hermes LAN discovery fails** (Bonjour unreliable across subnets) | Medium | High | Fallback to manual IP entry. Long-term: cloud proxy endpoint. |
| 2 | **Firestore read costs explode** (snapshot listeners on large collections) | Medium | High | Use pagination for session logs (already in `ActivityStore`). |
| 3 | **macOS view files are huge** (ChatPanel: 899 lines, SessionLogs: 1415 lines) | High | Medium | Port incrementally. Extract subviews first. Do not copy-paste blindly; refactor into smaller iPad components. |
| 4 | **iPhone layout breaks** from shared component changes | Medium | High | Run iPhone sim tests after every shared component change. Keep iPhone tab bar untouched. |
| 5 | **Stage Manager window resizing** causes layout issues | Medium | Medium | Never use fixed widths. Always use `GeometryReader` + `horizontalSizeClass`. Test all views at 320pt–1366pt widths. |

---

## 11. Phase Breakdown

### Phase 1: MVP — Dashboard + Auth + Settings (Weeks 1-8)

**Goal:** A usable iPad dashboard that a user can open, see their burn, and configure settings.

**Deliverables:**
- `RootNavigationView` with `NavigationSplitView`
- `DashboardOverviewView` with hero metrics, narrative card, provider/model lanes
- `ProviderDashboardView` + `ModelDashboardView` drill-ins
- All 7 settings tabs (General, Account, Providers, Alerts, Notifications, Devices & Sync, Account Switcher)
- Onboarding wizard (skip scan)
- iPhone compatibility preserved

**Tests:**
- Unit tests for `DashboardNavigationModel`
- UI test: onboarding → sign-in → dashboard → settings → sign-out

### Phase 2: Chat + Session Logs (Weeks 9-12)

**Goal:** Rich conversation history and Hermes chat.

**Deliverables:**
- `SessionLogsView` with two-pane search + detail
- `ChatView` full-screen Hermes chat
- `HermesChatClient` with SSE streaming
- `BonjourDiscovery` for LAN Hermes
- `ChatStore` for Firestore chat thread sync

**Tests:**
- Unit tests for `HermesChatClient` (mocked URLSession)
- UI test: open chat → send message → verify bubble appears

### Phase 3: Projects + Notifications (Weeks 13-16)

**Goal:** Project hub and daily digest notifications.

**Deliverables:**
- `ProjectsView` with list + hub drill-in
- `ProjectStore` for Firestore project/mission reads
- `DailyDigestManager` for local notifications

**Tests:**
- Notification scheduling test

---

## 12. Design System Parity Checklist

Before shipping, verify every token from macOS `DesignSystem.swift` exists in `MobileTheme.swift`:

- [ ] `hermesMercury` / `hermesAureate` / `mercuryGradient`
- [ ] `mercuryShimmer` animation curve
- [ ] `glassCard` material + gradient stroke pattern
- [ ] Provider chart palettes (`chartPalette(for:)`)
- [ ] Model color hashing (`colorForModel`, `gradientForModel`)
- [ ] `Animation.standard` / `.gentle` / `.snappy` / `.hover`
- [ ] `Radius.sm/md/lg/xl/full`
- [ ] `Spacing.xxs` through `xxxl`
- [ ] `Typography.displayLarge` through `monoTiny`
- [ ] `chatUserStroke` / `chatAssistantStroke`

---

## 13. SwiftUI Correctness Checklist (per swiftui-expert-skill)

- [ ] All `@State` properties are `private`
- [ ] `@Binding` only where child modifies parent state
- [ ] Passed values never declared as `@State` or `@StateObject`
- [ ] `@StateObject` for view-owned objects; `@ObservedObject` for injected
- [ ] `ForEach` uses stable identity (never `.indices` for dynamic content)
- [ ] Constant number of views per `ForEach` element
- [ ] `.animation(_:value:)` always includes the `value` parameter
- [ ] iOS 26+ APIs gated with `#available` and fallback provided
- [ ] `import Charts` present in files using chart types

---

## 14. Reference Files

- `AGENTS.md` — Agent coding standards (boil the ocean)
- `DESIGN.md` — Design system (colors, typography, motion)
- `docs/research_ipados_porting_2026.md` — iPadOS constraints research
- `docs/IOS_APP_ARCHITECTURE.md` — Existing mobile architecture
- `AgentLens/Views/` — macOS view source (copy from here)
- `OpenBurnBarMobile/` — Existing mobile source (extend from here)
- `OpenBurnBarCore/` — Shared models/contracts
