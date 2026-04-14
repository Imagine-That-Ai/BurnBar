# User Testing

## Validation Surface

### Surface CP1: ContextPack service ranking/capping/export core
- Scope: ranking heuristics, deterministic tie-breaks, session cap, char cap, oldest-first trimming, dedupe, reason labels, usage summary, target envelope correctness.
- Tools: `xcodebuild test` scoped suites:
  - `OpenBurnBarTests/ContextPackServiceTests`
  - `OpenBurnBarTests/ContextPackExportTests`

### Surface CP2: Dashboard Context Pack UI
- Scope: card placement, sheet presentation, target pill behavior, copy flow, budget threshold states, empty-state safeguards, modal collision behavior.
- Tools: `xcodebuild test` scoped suite:
  - `OpenBurnBarTests/ContextPackDashboardSurfaceTests`

### Surface CP3: Session Detail Context Pack UI
- Scope: row gating and ordering, anchored launch identity/project, rapid-switch stability, stale-state prevention, reachability from provider/model ledger flows.
- Tools: `xcodebuild test` scoped suite:
  - `OpenBurnBarTests/ContextPackSessionDetailSurfaceTests`

### Surface CP4: Cross-area consistency
- Scope: same-anchor parity across entrypoints, target-switch envelope-only changes, lifecycle resilience, anchored-vs-unanchored policy, anchor precedence over ambient dashboard filters.
- Tools: `xcodebuild test` scoped suite:
  - `OpenBurnBarTests/ContextPackCrossFlowTests`

## Validation Concurrency

- Heavy validators (`xcodebuild`): **max 1 concurrent**
- Lint/lightweight commands: **max 2 concurrent**
- Rationale: local machine had high background CPU load during dry run; serializing heavy app-test runs reduces flake risk.

## Accepted Constraints

- User explicitly opted out of manual UI checks for this mission.
- Validation therefore relies on deterministic app tests/build gates and export-content assertions.

## Preferred Validation Commands

```bash
xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/ContextPackServiceTests" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''
xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/ContextPackExportTests" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''
xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/ContextPackDashboardSurfaceTests" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''
xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/ContextPackSessionDetailSurfaceTests" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''
xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination "platform=macOS,arch=arm64" -only-testing:"OpenBurnBarTests/ContextPackCrossFlowTests" CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY='' DEVELOPMENT_TEAM=''
```
