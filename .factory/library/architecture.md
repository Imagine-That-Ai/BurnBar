# Architecture

## Mission Scope
Build a native BurnBar multi-account switcher for fast profile-based switching across:
- Browser targets: Chrome, Safari
- CLI targets: Codex, Claude, OpenCode

Security model is strict: **no credential scraping/import**, metadata-only profile switching.

## Core Components

### 1) Profile Registry + Persistence
- Canonical local store for switcher profiles.
- Profile types:
  - Browser profile (`chrome` or `safari`)
  - CLI profile (`codex`, `claude`, `opencode`)
- Persists non-secret launch metadata only (labels, target type, profile reference, options).
- Tracks active profile state and last-used metadata deterministically.

### 2) Switch Orchestrator
- Single boundary for all switch actions.
- Enforces invariants:
  - Exactly one active profile per domain.
  - Deterministic state transitions (`idle -> switching -> success|failure`).
  - No split-brain state under rapid inputs (serialized/coalesced actions).

### 3) Launch Adapters
- **Browser launcher adapter**
  - Launches explicit app target (Chrome/Safari) using selected profile reference.
  - Uses allowlisted arguments only.
  - Never touches cookie/session/auth files.
- **CLI launcher adapter**
  - Resolves trusted executable for Codex/Claude/OpenCode.
  - Builds explicit argv and allowlisted env.
  - No shell interpolation.

### 4) UI Surfaces
- **Settings**: full profile management (create/edit/delete/activate, validation, boundary copy).
- **Dashboard**: quick switch and launch actions with clear status/recovery.
- **Menu bar popover**: fastest compact switch flow, keyboard/mouse parity, deterministic feedback.

### 5) Cross-Surface State Synchronization
- Shared observable active-profile state consumed by Settings, Dashboard, and Popover.
- Navigation handoffs preserve active context.
- App relaunch restores active profile consistently on all three surfaces.

## Data Flow
1. User creates/edits profile in Settings.
2. Profile store validates and persists metadata-only record.
3. Active profile changes are published through switch orchestrator.
4. Dashboard/Popover render updated active state.
5. Launch action uses currently active profile and dispatches to browser/CLI adapter.
6. Adapter returns success/failure with typed diagnostics; UI shows actionable feedback.

## Security and Safety Invariants
- No cookie/session import path exists in UI or API.
- No raw OAuth credentials/tokens/passwords in plaintext profile storage.
- Browser and CLI launch logs are redacted and secret-safe.
- Browser profile/session/auth files are never mutated by switcher flows.
- CLI launches enforce trusted executable resolution, argv hardening, and env allowlisting.

## UX Invariants
- Switch operations are quick and understandable with explicit in-progress/success/error states.
- Empty, loading, and error states always include a recovery path.
- Keyboard and accessibility semantics are first-class for all primary actions.

## Failure Handling Invariants
- Missing profile/app/executable produces typed, actionable errors.
- Failed launch does not corrupt active profile state.
- Rapid repeated actions resolve deterministically.
