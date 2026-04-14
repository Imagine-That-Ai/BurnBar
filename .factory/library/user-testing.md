# User Testing

## Validation Surface

### Surface CP1: ContextPack service ranking/capping/export core
- Scope: ranking heuristics, deterministic tie-breaks, session cap, char cap, oldest-first trimming, dedupe, reason labels, usage summary, target envelope correctness.
- Tools: `xcodebuild test` scoped suites:
  - `OpenBurnBarTests/ContextPackServiceTests`
  - `OpenBurnBarTests/ContextPackExportTests`
- Coverage note: current service tests prove deterministic ordering and cap trimming separately, but they do not yet include an exact equal-score/equal-timestamp fixture that forces final ID-ascending survivor selection under cap pressure.
- Export contract note: `VAL-CTXEXP-006` is exercised by `test_xmlSensitiveKeyFilesAndCommandsPreserveEnvelopeIntegrity`; the older XML-safety annotation in the repo is stale.

## Flow Validator Guidance: Surface CP1

- Treat CP1 as a serialized heavy surface: run only one `xcodebuild` validator at a time.
- Use a unique derived-data path per subagent under `.factory/validation/m1-context-pack-core/user-testing/derived-data/<group-id>` to avoid build-product collisions.
- No app services or seeded runtime data are required for this surface; tests should rely on deterministic fixtures only.
- Do not touch or probe unrelated busy ports/processes; this milestone is test-only.
- If a fixture gap is discovered (for example, a missing exact equal-score/equal-timestamp survivor case), record it in the synthesis report instead of altering product code.
- The flow-report finalization script now resolves the `m1-context-pack-core` default report set automatically; pass explicit filenames only when you need to override the built-in mapping (`cp1-service-ranking.json`, `cp1-service-cap.json`, `cp1-service-dedupe.json`, `cp1-export-envelopes.json`).

### Surface CP2: Dashboard Context Pack UI
- Scope: card placement, sheet presentation, target pill behavior, copy flow, budget threshold states, empty-state safeguards, modal collision behavior.
- Tools: `xcodebuild test` scoped suite:
  - `OpenBurnBarTests/ContextPackDashboardSurfaceTests`

## Flow Validator Guidance: Surface CP2

- Treat CP2 as a serialized heavy surface: run only one `xcodebuild` validator at a time.
- Use a unique derived-data path per subagent under `.factory/validation/m2-context-pack-ui/user-testing/derived-data/<group-id>` to avoid build-product collisions.
- No app services or seeded runtime data are required; validate through deterministic `xcodebuild` fixtures only.
- Keep the scope confined to `OpenBurnBarTests/ContextPackDashboardSurfaceTests`; do not rely on manual UI interaction or shared app runtime state.
- Save the flow report under `.factory/validation/m2-context-pack-ui/user-testing/flows/<group-id>.json` and evidence under `.../evidence/<group-id>/`.

### Surface CP3: Session Detail Context Pack UI
- Scope: row gating and ordering, anchored launch identity/project, rapid-switch stability, stale-state prevention, reachability from provider/model ledger flows.
- Tools: `xcodebuild test` scoped suite:
  - `OpenBurnBarTests/ContextPackSessionDetailSurfaceTests`

## Flow Validator Guidance: Surface CP3

- Treat CP3 as a serialized heavy surface: run only one `xcodebuild` validator at a time.
- Use a unique derived-data path per subagent under `.factory/validation/m2-context-pack-ui/user-testing/derived-data/<group-id>` to avoid build-product collisions.
- The tests must exercise the real SwiftUI entry surfaces (`SessionDetailView` and the Context Pack launch path); helper-only assertions are insufficient for the UI selectors in this surface.
- No app services or seeded runtime data are required; keep the surface deterministic and avoid touching unrelated local ports or processes.
- Save the flow report under `.factory/validation/m2-context-pack-ui/user-testing/flows/<group-id>.json` and evidence under `.../evidence/<group-id>/`.

### Surface CP4: Cross-area consistency
- Scope: same-anchor parity across entrypoints, target-switch envelope-only changes, lifecycle resilience, anchored-vs-unanchored policy, anchor precedence over ambient dashboard filters.
- Tools: `xcodebuild test` scoped suite:
  - `OpenBurnBarTests/ContextPackCrossFlowTests`

## Flow Validator Guidance: Surface CP4

- Treat CP4 as a serialized heavy surface: run only one `xcodebuild` validator at a time.
- Use a unique derived-data path per subagent under `.factory/validation/m2-context-pack-ui/user-testing/derived-data/<group-id>` to avoid build-product collisions.
- Keep cross-flow assertions scoped to the Context Pack dashboard/session-detail entry surfaces; do not mutate shared app state outside the tested harness.
- No services or external seeding are needed. Validate semantic parity and navigation resilience through the deterministic `xcodebuild` suites only.
- Save the flow report under `.factory/validation/m2-context-pack-ui/user-testing/flows/<group-id>.json` and evidence under `.../evidence/<group-id>/`.

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
