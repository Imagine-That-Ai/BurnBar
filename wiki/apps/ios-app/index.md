# iOS companion app

`OpenBurnBarMobile` is a native SwiftUI iOS/iPadOS 17+ companion for OpenBurnBar. It delivers real-time usage stats mirrored from the Mac, Mercury calls, Computer Use live mirror, and Hermes chat in a single tab-based app.

## Targets

- `OpenBurnBarMobile` — iOS/iPadOS app
- `OpenBurnBarMobileTests` — unit tests (~59 test files)

## Directory layout

```
OpenBurnBarMobile/
  App/
    AppDelegate.swift          — UIApplicationDelegate, push/VoIP registration
    AppStoreScreenshotMode.swift
    AuthGateView.swift         — root auth gate, owns singleton stores
    OpenBurnBarMobileApp.swift — SwiftUI App entry point, scene setup
  Views/
    Aurora/                    — animated backdrop, breathing orbs
    Budget/                    — budget capsule UI
    Burn/                      — burn-rate views
    Chat/                      — Hermes chat panel
    ChartStudio/               — chart rendering
    CLIAgents/                 — CLI agent panels
    Components/                — shared primitives (GlassCard, badges, etc.)
    ComputerUse/               — AgentLiveStage, AgentWatchView, empty state
    Hermes/                    — Hermes strip, tool cards, thinking state
    Insights/                  — Editorial Observatory (Intelligence Brief)
    Media/                     — Mercury call UI, attachment bubbles
    MissionControl/
    Navigation/
    Onboarding/
    Pulse/
    SmartHub/
    Store/
    Streams/
    You/                       — You-tab: Agent Watch, Computer Use entry point
    Dashboard/*, Quota/*, Activity/*, Account/* (top-level view files)
```

## Navigation

```
OpenBurnBarMobileApp
  └─ AuthGateView
       ├─ FirebaseUnavailableScene
       ├─ SignInScene
       └─ RootTabView
            ├─ Dashboard    — usage rollups, hero total, top providers
            ├─ Quota        — quota snapshots, urgency sort
            ├─ Activity     — paginated token-usage events
            └─ You          — devices, Agent Watch, Computer Use
```

## Key features

### Agent Watch / AgentLiveStage

Live mirror of the Mac agent session with tap-to-drive capability:

| State | UI |
|---|---|
| **Dock tile** | 320×180 (compact) / 360×203 (regular) mercury-stroked tile in RootTabView ZStack |
| **Split** | Top 55% mirror (compact) or leading 60% (regular); chat remains accessible |
| **Maximize** | Full-bleed mirror + 56pt draggable `AgentLiveStageChatPuck` floating composer |

- Auto-opens when a Computer Use `sessionId` arrives.
- Taps (<10pt) route to `AgentWatchReceiver.tap(normalizedX:y:)`.
- Drags route to `scrollDrag(...)`.
- "YOU ARE DRIVING" mercury pill appears on first input and after 4-second input lulls.
- Session-end: 6s grace window so final animations finish; cancels if a new session arrives mid-window.
- `AgentWatchOverlaySingleton` owns the persistent iroh stream across tab swaps — `AgentWatchScreen` is a passive viewer of the same singleton.

Tests: `AgentLiveStagePresenterTests` (13 cases), `AgentLiveStageWiringTests` (5 cases).

### Mercury incoming calls

- Registered as a PushKit VoIP receiver in `AppDelegate`.
- Incoming call invokes `CallKit` for the native system call sheet, lock-screen wake, and ringer.
- `CXCallController` handles accept/decline; audio routes through `MercuryAudioDatagramChannel` over iroh.

### Hermes chat

- Same dual-backend panel as macOS (Local Index + Hermes webapi).
- Mercury-stroked bubbles in Hermes mode with `mercuryPool` thinking animation.
- Tool cards collapsed after completion, expandable.

### Insights — Editorial Observatory

The Intelligence Brief (`Views/Insights/`) follows the Editorial Observatory design:

- Eyebrow + 22pt headline + mono meta strip + mercury hairline hero
- Numbered 01/02/03 Top Findings with 3pt severity-bar leading edge
- Horizontal Anomaly Atlas (220pt cards, mono z-score)
- Recommendations with ember seal and mono impact arrow
- Cascade-in at 0.04s stagger, respects `accessibilityReduceMotion`
- Dynamic Type clamped to `.xxLarge`

## iroh transport

`OpenBurnBarIroh.xcframework` — Rust crate (`crates/openburnbar-iroh`) compiled via `cargo-ndk` with UniFFI Swift bindings. The framework is embedded in the app bundle; an `IrohBlobKeyStore` manages blob hash → key associations.

## Store layer

Views talk to `@Observable @MainActor` stores:

| Store | Data |
|---|---|
| `AuthStore` | Sign-in state, classified auth errors |
| `DashboardStore` | Usage rollups, hero total, period totals |
| `QuotaStore` | Quota snapshots, urgency sort |
| `ActivityStore` | Paginated `TokenUsage` events |
| `ConversationCockpitStore` | Faceted conversation search, on-device decrypt |
| `DevicesStore` | Devices list, trust state, bootstrap |

All stores consume Firestore via typed gateway adapters — views never import Firestore types directly.

## Build

```bash
# Open in Xcode
open BurnBar.xcworkspace

# Run tests
./scripts/test-openburnbar-mobile.sh
```

## Related

- [Computer Use](../../features/computer-use.md)
- [Mercury media](../../features/mercury-media.md)
- [Hermes chat](../../features/hermes-chat.md)
- [Android companion app](../android-app.md)
- `docs/IOS_APP_ARCHITECTURE.md` — full architecture reference
