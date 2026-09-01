# Cross-Platform Bug Reporting & CLI Auto-Dispense System

## Overview

OpenBurnBar includes an integrated, zero-friction bug reporting and issue resolution loop across **macOS**, **iOS**, and **Android**. When a user encounters an issue, bug report submissions automatically create a tracked issue in **Linear** and immediately dispense a local CLI agent (Claude Code, Codex, Antigravity, or Droid) on the developer's Mac to reproduce, debug, and fix the issue.

```
┌─────────────────────────────────────────────────────────────┐
│                      Client Surfaces                        │
│   • macOS: Menu Bar, ⌥⌘B Shortcut, Help & Support Hub       │
│   • iOS: Settings → Help & Support, Shake-to-Report Sheet   │
│   • Android: Settings → Help & Support, Shake Sensor Modal  │
└──────────────────────────────┬──────────────────────────────┘
                               │ HTTPS Callable (`submitBugReport`)
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                 Cloud Functions Backend                     │
│   • Diagnostic Sanitization (auto-redacts tokens & secrets) │
│   • Linear GraphQL Client (creates Linear ticket / BB-XXX)  │
│   • Firestore Persistence (`users/{uid}/bug_reports/`)      │
│   • Auto-creates `cli_agent_mission_requests` document      │
└──────────────────────────────┬──────────────────────────────┘
                               │ Firestore Real-Time Snapshot
                               ▼
┌─────────────────────────────────────────────────────────────┐
│                  macOS Daemon & CLI Host                    │
│   • `CLIAgentMissionRequestListener` detects mission        │
│   • Claims & sets status to `running` via Cloud Functions   │
│   • Launches Interactive Terminal (Claude/Codex/Droid/AGY)  │
│     with Linear ticket context, logs, and prompt            │
└─────────────────────────────────────────────────────────────┘
```

---

## 1. Client Surfaces

### macOS App
- **Help Menu & Status Item**: "Report Bug or Feedback…" with key shortcut `⌥⌘B`.
- **Help & Support Hub**: `HelpSupportHubView.swift` accessible via menu or `openburnbar://support` deep link, offering system health diagnostics and quick access to the reporting sheet.
- **Reporting Sheet**: `BugReportSheetView.swift` modal featuring category selection, title, reproduction steps, system diagnostics toggle, and CLI agent auto-dispatch toggle.
- **Diagnostics**: `SystemDiagnosticsCollector.swift` gathers OS version, Mac model, active memory, thermal state, and daemon connectivity.

### iOS App
- **Settings Hub Navigation**: Dedicated "Help & Support" row in `SettingsHubView.swift` navigating to `MobileHelpSupportHubView.swift`.
- **Shake to Report**: `ShakeGestureManager.swift` detects physical device shake gestures to trigger `MobileBugReportSheetView.swift`.
- **Diagnostics**: `MobileDiagnosticsCollector.swift` captures iOS version, device model, battery status, and thermal state.

### Android App
- **Help & Support Screen**: `HelpSupportScreen.kt` with device diagnostics and one-tap bug report launcher.
- **Bottom Sheet Modal**: `BugReportBottomSheet.kt` Compose component with full category, title, description, and agent dispatch controls.
- **Shake Detection**: `ShakeDetector.kt` listens to accelerometer sensor motion.
- **Diagnostics**: `AndroidDiagnosticsSnapshot` captures OS API level, manufacturer, model, and hardware board.

---

## 2. Backend Architecture

### `submitBugReport` Cloud Function (`functions/src/callables/bugReporting.ts`)
- Registered via `onCallProduction` with Sentry logging and App Check attestation support.
- Validates user authentication and required payload fields (`title`, `description`, `platform`).
- Redacts sensitive credential patterns, auth tokens, and passwords from diagnostics.
- Calls `LinearClient` to create the ticket.
- When `autoDispenseCLI` is enabled, creates a mission record in `users/{uid}/cli_agent_mission_requests/mission_bug_{reportId}` with `missionKind: "bug_investigation"`.

### Linear GraphQL Client (`functions/src/linear/linearClient.ts`)
- Communicates directly with Linear API (`https://api.linear.app/graphql`) via resilient fetch.
- Automatically resolves team IDs and creates issues with rich markdown formatting including environment details, diagnostics JSON, and log snippets.
- Includes offline/mock fallback generating structured mock identifiers (`BB-XXX`) when `LINEAR_API_KEY` is unconfigured.

---

## 3. Local CLI Agent Dispense Loop

1. When a bug report is submitted, a Firestore document is placed into `users/{uid}/cli_agent_mission_requests/{missionId}`.
2. The macOS daemon (`CLIAgentMissionRequestListener.swift`) listens for pending missions.
3. `CLIAgentMissionRuntimePlanner.swift` detects `missionKind == "bug_investigation"` and formats a specialized prompt instructing the AI agent to:
   - Review the Linear ticket description and user reproduction steps.
   - Inspect local repository logs and recent test outputs.
   - Formulate a diagnosis, write reproduction unit tests, and implement a patch.
4. `CLIAgentMissionHostHandling.swift` claims the mission and spawns the interactive CLI terminal via `InteractiveTerminalLauncher.swift` running the configured assistant (Claude Code, Codex, Antigravity, or Droid).
