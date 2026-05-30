# Computer Use

Computer Use lets an AI agent drive your Mac (browser automation and full system control) while you watch and approve actions from your iPhone or iPad. The phone mirrors the Mac screen live and can send signed input intents back.

## Phases

| Phase | Capability | Remote Config flag |
|---|---|---|
| 8 | Agent Watch — read-only screen mirror (Mac → phone) | `computer_use_watch_enabled` |
| 9 | Browser CU — agent drives Playwright Chromium | `computer_use_browser_enabled` |
| 10 | Trust modes + audit chain | `computer_use_trust_modes_enabled` |
| 11 | Mac System CU — CGEvent + Accessibility API | `computer_use_system_enabled` |
| 12 | Phone-as-controller — Ed25519-signed intents | `computer_use_phone_control_enabled` |
| 13 | Polish — trusted-scope library, audit export, OpenTimestamps | `computer_use_polish_enabled` |

All phases ride the existing iroh QUIC mesh (`openburnbar/1` ALPN). No new ALPN or transport is added.

## Trust modes

Trust mode is per-session and never persists across sessions.

| Mode | Approval requirement |
|---|---|
| **Manual** | Every action requires approval. Default; reset target on lock/kill. |
| **Step** | Burst of ≤10 actions or 30 s before re-approval. "Approve next 10" toggle on approval sheet. |
| **Trusted** | Only when an action exits an active scope rule. Phone can downgrade to Step/Manual; only the Mac can upgrade. |

Mode lives in `ComputerUseSessionDoc.trustMode` (Firestore).

## Panic-kill paths

Three independent kill paths:

1. **⌃⌥⌘.** global hotkey on Mac
2. **3-finger long-press** on the phone screen
3. **Remote Config kill switch** — `computer_use_kill_switch` flips the Remote Config flag; `ComputerUseRemoteConfigNotifications.swift` observes it

A fourth gate: macOS lock, screen sleep, loginwindow, and SecurityAgent all halt agent and Computer Use sessions via `MercuryRouter`.

## Audit chain

- Every approved/denied action is written as a content-addressed entry (SHA-256 today, BLAKE3-swappable).
- Tamper detection covers every entry including the terminal one when `head.json` is supplied.
- The audit chain panel in `ComputerUseSessionPanel` shows the 10 most recent entries with mono ordinals (`01`, `02`, …) and SF Symbol status glyphs.

## Wire protocol

Computer Use extends the Mercury Media frame format:

```
MediaFrame header (18 bytes)
+ [optional] 4 bytes cursor extension (i16 cursorX, i16 cursorY, big-endian)
  when Flags bit 0x08 (hasCursorMetadata) is set
```

Old peers that do not set `0x08` ignore the trailing 4 bytes — backward-compatible.

New `HermesRealtimeRelayFrameType` cases handle control:
- `control.action.log.entry` — Mac → phone (planned/executing/completed/failed)
- `control.input.intent` — phone → Mac (Ed25519-signed)
- `control.approval.request` / `control.approval.response` — bidirectional
- `control.agent_grant.request` / `control.agent_grant.receipt` — capability grants

## iOS: AgentLiveStage

When a Computer Use `sessionId` arrives, `AgentLiveStage` auto-springs into the `RootTabView` ZStack:

```mermaid
graph LR
    S[Session starts] --> D[Dock tile 320×180]
    D -->|tap| SP[Split 55% mirror]
    SP -->|pinch-out or chevron| M[Maximize full-bleed]
    M --> P[AgentLiveStageChatPuck floating composer]
```

- **Dock tile** (compact): 320×180, mercury-stroked, always visible while a session is active.
- **Split**: top 55% on compact, leading 60% on regular; chat remains accessible below/beside.
- **Maximize**: full-bleed mirror + 56pt draggable `AgentLiveStageChatPuck` for messaging.
- Input routes taps (<10pt) to `AgentWatchReceiver.tap(normalizedX:y:)` and drags to `scrollDrag(...)`.
- "YOU ARE DRIVING" mercury pill fades in on first input and after 4-second input lulls.
- Session-end uses a 6s grace window so final animations complete before the dock collapses.

`AgentWatchOverlaySingleton` owns the persistent iroh control stream across tab swaps.

## iOS empty state

`AgentWatchEmptyStateView` replaces the old blank placeholder:

- Hero section: caduceus glyph, "COMPUTER USE" eyebrow, 24pt headline, phase badge (STANDBY/DIALING/RECONNECTING/LIVE/ERROR)
- Setup checklist: Signed in / Hermes Remote Relay selected / Live session — each with a CTA pill
- 01/02/03 ordered setup guide with mono ordinals
- 2×2 capability strip: Live mirror / Tap to drive / Full audit / Panic halt
- CTAs wire through `HermesService.connectToSuggestedRelay(refresh:)` for one-tap relay selection

## Budget governance

| Limit | Value |
|---|---|
| Soft cap | $1,500/mo; 25 actions/run · 100/day |
| Hard cap | $2,500/mo → Remote Config kill switch |
| Per-user daily ceiling (normal) | $5 |
| Per-user daily ceiling (soft cap) | $2.50 |
| Per-user daily ceiling (hard cap) | $0 |

`evaluateComputerUseBudget` Cloud Function evaluates hourly.

## Key files

| File | Role |
|---|---|
| `AgentLens/Services/ComputerUse/ComputerUseSessionCoordinator.swift` | Session lifecycle, trust-mode management (~74 KB) |
| `AgentLens/Services/ComputerUse/ComputerUseRuntimeController.swift` | Runtime action dispatch |
| `AgentLens/Services/ComputerUse/ComputerUsePanicHaltCoordinator.swift` | Panic-kill logic |
| `AgentLens/Services/ComputerUse/PhoneControlReceiver.swift` | Ed25519 intent validation |
| `AgentLens/Services/ComputerUse/Mac/` | CGEvent + AX system-level drivers (Phase 11) |
| `AgentLens/Services/ComputerUse/SystemPermissionMonitor.swift` | Accessibility/Screen Recording gates |
| `OpenBurnBarMobile/Views/ComputerUse/` | iOS mirror surfaces, AgentLiveStage, empty state |
| `OpenBurnBarDaemon/Resources/PlaywrightBridge/openburnbar-playwright-bridge.js` | Browser CU driver (Phase 9) |

## Distribution note

The Mac System CU path (Phase 11) ships only via direct download with notarization. The MAS build compiles it out via `#if DISTRIBUTION_MAS`.

## Related

- [Mercury media](./mercury-media.md) — iroh transport substrate Computer Use rides
- [Hermes chat](./hermes-chat.md) — the chat interface where Computer Use sessions can be initiated
- `docs/HERMES_COMPUTER_USE.md` — full operator and engineer reference
- `plans/2026-05-16-computer-use-master-plan.md` — master plan with locked decisions
