# Apps

OpenBurnBar ships four deployable units. Each targets a different platform and user context, but all share the same `OpenBurnBarCore` wire types and Firestore schema.

## macOS app

**Location:** `AgentLens/`

The primary surface. A native macOS menu bar app that watches local provider log directories, parses token usage, and displays real-time spend in a popover dashboard and settings window. Houses the Hermes chat panel (Local Index and Hermes webapi modes), the Computer Use runtime (Agent Watch, Browser CU, Mac System CU), the daemon installer/repairer, and all provider-key management.

→ [macOS app](macos-app/index.md)

## iOS companion

**Location:** `OpenBurnBarMobile/`

iPhone and iPad companion app. Primary surfaces:

- **Computer Use / Agent Watch** — live mirror of Mac screen with tap-to-drive and panic-halt
- **Mercury** — 1:1 calls, file transfer, screen share over iroh transport
- **Insights** — editorial Observatory view of token spend trends

→ [iOS app](ios-app/index.md)

## Android companion

**Location:** `android/`

Kotlin/Jetpack Compose Android companion reaching full iOS parity as of 2026-05-16: Hermes Square, messaging, iroh transport, Mercury Media (file transfer, screen-share viewer, 1:1 calls). Data layer mirrors `functions/src/types.ts` canonical schema via annotated Kotlin data classes.

→ [Android app](android-app.md)

## VS Code / Cursor extension

**Location:** `extensions/openburnbar/`

TypeScript extension providing a sidebar panel inside VS Code and Cursor. Shows daemon health, projected run state, and workspace capability gating. Does not yet have run start/cancel/approval controls.

→ [VS Code / Cursor extension](vscode-extension.md)
