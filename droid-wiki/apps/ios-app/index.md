# iOS companion app

SwiftUI companion for Computer Use mirroring, Mercury calls and file transfer, Hermes chat, and Insights. Targets iPhone and iPad; built with the same iroh transport and Firebase backend as the macOS app.

## Directory layout

```
OpenBurnBarMobile/
├── App/              — App entry point, environment setup
├── Features/         — Feature modules (Computer Use, Mercury, Missions, etc.)
├── Intents/          — App Intents / Shortcuts integration
├── Models/           — Shared data models
├── Services/         — Service layer (analytics, quota, sync, VoIP)
├── Views/            — All SwiftUI views (see below)
│   ├── Aurora/       — Aurora nav tray and ambient animations
│   ├── Chat/         — Hermes/Local Index chat panel
│   ├── ComputerUse/  — Agent Watch, Live Stage, trust-mode UI
│   ├── Hermes/       — Hermes-specific overlays and strips
│   ├── Insights/     — Editorial Observatory intelligence brief
│   ├── Media/        — Mercury call UI, attachment bubbles
│   ├── Pulse/        — Usage pulse/dashboard
│   ├── You/          — Profile, Computer Use screen, settings
│   └── ...           — (40+ additional view files)
├── Theme/            — Design system tokens, adaptive colors
├── Settings/         — Settings views
└── Resources/        — Assets, localizations
```

## Key features

### Agent Watch / Agent Live Stage

When the Mac starts a Computer Use session, the iOS app auto-opens a dock tile without any user gesture:

| Stage | Size | Trigger |
|---|---|---|
| Dock tile | 320×180 (compact), 360×203 (regular) | Session `sessionId` received |
| Split | Top 55% (compact), leading 60% (regular) | Tap dock tile |
| Maximize | Full-bleed mirror + floating chat puck | Pinch out or expand chevron |

- **Floating chat puck**: 56 pt draggable; expands to a 320×420 mercury-stroked composer.
- **Driving indicator**: "YOU ARE DRIVING" mercury pill appears on first touch input and after 4 s of inactivity.
- **Panic halt**: one-tap `ComputerUsePanicHaltCoordinator` accessible from all stages.
- **Grace window**: 6 s after session end before the dock tile collapses.
- `AgentWatchOverlaySingleton` persists the iroh stream across tab navigation.

### Mercury calls

- Incoming calls arrive via APNs VoIP push (PushKit), triggering a full CallKit incoming-call screen.
- `VoIPCallTrigger` on the Mac side fires the `triggerVoIPCall` Cloud Function.
- In-call UI lives under `OpenBurnBarMobile/Views/Media/`.

### Hermes chat

Same dual-backend system as macOS:
- **Local Index mode**: CLI subprocess bridge, stateless per-turn.
- **Hermes mode**: HTTP SSE to `localhost:8642`, multi-turn memory, mercury-stroked bubbles, collapsible tool cards.

Chat views live under `OpenBurnBarMobile/Views/Chat/` and `Views/Hermes/`.

### Insights — Editorial Observatory

Located under `OpenBurnBarMobile/Views/Insights/`. The brief presents:

- `INTELLIGENCE BRIEF` eyebrow + `Last 7 days` subtitle + 22 pt rounded-semibold executive lede.
- Mercury-gradient hairline hero with one-shot shimmer.
- 01/02/03 numbered findings with severity bars, confidence dots, footnote-chip citations, and `→` action stripe.
- Horizontal Anomaly Atlas scrolling cards with mono z-score labels.
- Recommendations with ember seal and mono impact arrow (direction inferred from sign: `−` → `↘` savings, `+` → `↗` cost increase).
- Generated views via `InsightWidgetRenderer`; follow-up chips via `IntelligenceBriefCitationPrompt`.
- Cascade-in at 0.04 s stagger; respects `accessibilityReduceMotion`.

## iroh transport

`OpenBurnBarIroh.xcframework` provides Rust UniFFI bindings for the iroh P2P library. Compiled for `arm64-apple-ios` and `arm64-apple-ios-simulator`.

Build script: `scripts/build-iroh-android-aar.sh` handles the Android equivalent; the iOS xcframework is pre-built in `Vendor/`.

## Tests

Test target: `OpenBurnBarMobileTests` (~59 test files).

```bash
# Run on a connected physical device (recommended)
./scripts/test-openburnbar-mobile.sh

# Build and launch on Simulator
./scripts/cross-platform/run-ios
```

CI uses Simulator fallback when no physical device is attached.
