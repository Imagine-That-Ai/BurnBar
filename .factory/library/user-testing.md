# User Testing

Testing surface guidance for BurnBar built-in account switcher validation.

---

## Validation Surface

### Surface A: Native macOS UI flows (primary)
- Scope: Settings, Dashboard, and Popover switcher behavior (management, switching, status/error/empty states, accessibility).
- Tools: `xcodebuild test` (UI/integration tests), scoped test targets.
- Notes: This is the highest-value user-facing surface.

### Surface B: Launch orchestration contracts (primary)
- Scope: Browser launch (Chrome/Safari), CLI launch (Codex/Claude/OpenCode), typed errors, race handling, safety constraints.
- Tools: `swift test`, scoped `xcodebuild test`, command-level smoke checks.

### Surface C: Cross-surface flows (primary)
- Scope: create in Settings -> use in Dashboard/Popover, global active-state consistency, relaunch persistence, cross-surface switch+launch chains.
- Tools: `xcodebuild test` integration/UI + event/log inspection.

### Surface D: Security and persistence checks (primary)
- Scope: metadata-only persistence, no cookie/session import, no plaintext secret leakage, log redaction.
- Tools: `swift test`, file/storage inspection commands, log scans.

## Validation Concurrency

User-approved profile: **max concurrent validators = 4**

Recommended scheduling:
- Heavy validators (`xcodebuild test`): **max 1 concurrent**
- Medium validators (`swift test` package suites): **max 1 concurrent**
- Lightweight smoke/log/storage checks: **up to 2 concurrent**

This keeps total concurrency at 4 while avoiding heavy-run contention.

## Flow Validator Guidance

- Run from repo root (`/Users/dewclaw/Documents/Projects/BurnBar`).
- Keep validator artifacts in `.factory/validation/<milestone>/user-testing/`.
- Include signing-off flags for Xcode runs when needed:
  - `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''`
- Prefer scoped commands tied to assertion IDs before broader suites.
- Respect protected local ports: `5000`, `7000`, `8642`, `11434`.
- For browser launch verification, use non-destructive app checks/smokes (`open -Ra`, targeted open commands) and pair with launcher invocation assertions.

## Evidence Expectations

- Command outputs with exit codes for each assertion group.
- UI evidence (snapshots/interaction traces) for Settings/Dashboard/Popover assertions.
- Launch invocation traces (target app/executable, profile ID, argv/env-allowlist evidence).
- Persistence/log evidence proving metadata-only storage and secret-safe logging.

## Flow Validator Guidance: xcodebuild-ui

- Scope: Settings switcher user-surface assertions (`VAL-SETTINGS-*`).
- Isolation boundary: read/write only `.factory/validation/core-engine/user-testing/flows/` and mission evidence folder assigned in prompt.
- Run only scoped UI/integration tests:
  - `xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/SwitcherSettingsUITests" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''`
- Do not start/stop unrelated services; no port/process mutations.

## Flow Validator Guidance: launch-contracts

- Scope: browser + CLI launch and security assertions (`VAL-BROWSER-*`, `VAL-CLI-*`).
- Isolation boundary: same repository only; no writes outside assigned flow report/evidence outputs.
- Preferred commands:
  - `xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/SwitcherBrowserLaunchTests" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''`
  - `xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/SwitcherCLILaunchTests" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''`
  - `open -Ra "Safari" && open -Ra "Google Chrome"`
- Keep logs/evidence secret-safe (no credential/token dumps).
