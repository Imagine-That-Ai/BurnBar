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

## Flow Validator Guidance: fast-surfaces-ui

- Scope: Dashboard + Popover quick-switch user-surface assertions for milestone `fast-surfaces` (`VAL-DASH-*`, `VAL-POPOVER-*`).
- Isolation boundary:
  - Read/write only the assigned flow report under `.factory/validation/fast-surfaces/user-testing/flows/`.
  - Save evidence only under the assigned mission evidence folder.
  - Do not modify application source code during validation.
- Execution constraints:
  - Use scoped xcode tests tied to assigned assertions only.
  - Keep to one heavy `xcodebuild test` process at a time across all validators.
  - Use signing-off flags when needed:
    - `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''`
- Allowed verification commands:
  - `xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/SwitcherDashboardUITests" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''`
  - `xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/SwitcherPopoverUITests" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''`
- Evidence note:
  - For `.xcresult` JSON extraction on current Xcode CLT, prefer `xcrun xcresulttool get object --legacy --path <bundle> --format json` over deprecated `get` forms.

## Flow Validator Guidance: m4-reconciliation-xcode

- Scope: token-accounting reconciliation/backfill hardening assertions for milestone `m4-reconciliation-backfill-hardening`:
  - `VAL-PERSIST-006`, `VAL-PERSIST-007`, `VAL-PERSIST-008`, `VAL-PERSIST-012`, `VAL-PERSIST-013`
  - `VAL-CROSS-003`, `VAL-CROSS-004`, `VAL-CROSS-005`, `VAL-CROSS-006`, `VAL-CROSS-010`
- Isolation boundary:
  - Read/write only assigned flow report path under `.factory/validation/m4-reconciliation-backfill-hardening/user-testing/flows/`.
  - Save evidence only under the assigned mission evidence folder.
  - Do not modify application source code during validation.
- Execution constraints:
  - Heavy `xcodebuild` runs are serialized (`max 1` concurrent heavy validator).
  - Use signing-off flags:
    - `CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''`
- Preferred scoped commands:
  - `xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/BackfillSchedulerTests" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''`
  - `xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/MultiSourceReconciliationTests" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''`
  - `xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/CrossSurfaceUpgradeTests" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''`
- Supplemental evidence commands:
  - `sqlite3 "$HOME/Library/Application Support/OpenBurnBar/OpenBurnBar.sqlite" "SELECT usageSource, COUNT(*) FROM token_usage WHERE usageSource='billing_api' GROUP BY usageSource;"`
