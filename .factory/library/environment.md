# Environment

Environment variables, external dependencies, and setup notes for Mission Control Fleet.

## What belongs here
- Required env vars and external credentials
- Local runtime prerequisites
- Integration assumptions for daemon/app/extension validation

## What does not belong here
- Service commands and validator commands (use `.factory/services.yaml`)
- Mission scope/requirements (use mission artifacts)

## Local prerequisites
- macOS with Xcode toolchain (Swift 5.10+)
- Node 20 for extension workspace
- `OpenBurnBarDaemon` and `OpenBurnBarCLI` buildable from `OpenBurnBarDaemon/Package.swift`

## Required integration credentials (real integrations only)
- Connector credentials needed for PR lifecycle validation (for example GitHub token/installation secrets through connector config paths)
- Any mission-specific external provider credentials required by daemon execution routes

If credentials are missing, related readiness checks must fail closed with explicit reason codes.

## Runtime assumptions
- Daemon is canonical source of mission state.
- App and extension are projections/interaction surfaces and must converge to daemon state.
- Mission-critical validation paths are real-integration paths unless explicit user-approved exception is recorded.

## Known local constraints
- Do not touch unrelated services/processes from other projects.
- Reserve temporary mission services to port range 3100–3199 if additional services are introduced later.
- Current frequently occupied ports include 5000, 7000, 5173, and 11434.
