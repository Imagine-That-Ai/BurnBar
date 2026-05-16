# Hermes iroh Rollout Status

## 2026-05-15 — Phase A local proof

**Gate status:** green. Local proof passed and GitHub checks are green on
commit `d1d5a1058`.

Completed:
- Rust host checks passed for `openburnbar-iroh` in debug and release.
- Rust Apple target release builds passed for `aarch64-apple-darwin`, `aarch64-apple-ios`, `aarch64-apple-ios-sim`, and `x86_64-apple-ios`.
- `scripts/build-iroh-xcframework.sh` produced `Vendor/OpenBurnBarIroh.xcframework` and UniFFI Swift bindings.
- `OpenBurnBarCore` builds with the local xcframework present and also builds from a fresh-checkout state when `Vendor/OpenBurnBarIroh.xcframework` is absent.
- `OpenBurnBar` macOS app build passed.
- `OpenBurnBarMobile` generic iOS device build passed.
- `OpenBurnBarMobile` iPhone 17 Pro Max simulator build passed.
- `functions` completed `npm ci && npx tsc --noEmit`.
- `OpenBurnBarCore` completed `swift build && swift test`: 641 tests passed, 2 skipped, 0 failures.
- GitHub `OpenBurnBarIroh xcframework` passed on commit `d1d5a1058`.
- GitHub `OpenBurnBar PR Harness` passed on commit `d1d5a1058`, including
  Functions lint/build/tests, Swift tests, app tests, TypeScript/eval suites,
  Firestore rules emulator tests, and Android APK build.

Notes:
- The generated xcframework is intentionally ignored at `Vendor/OpenBurnBarIroh.xcframework/` because the local artifact is 442 MB; CI and release lanes should regenerate/upload it rather than commit it.
- `OpenBurnBarCore/Package.swift` conditionally wires the UniFFI binary target only when the xcframework exists, so normal app CI can still compile the relay package without the binary artifact.
- The iOS adapter now has its own Keychain-backed `IrohRelayKeyStore` and Firestore audit logger; the audit protocol and event enums live in the shared relay package.

Next action:
- Phase A is closed. Continue Phase C dev round-trip validation; do not publish
  the hosted relay URL to production Remote Config until the Phase C gate is
  green.

## 2026-05-15 — Phase B infrastructure wiring

**Gate status:** green.

Completed:
- Verified local `IROH_SERVICES_API_SECRET` exists at `.secrets/iroh-services.env`, is mode `600`, and loads to a non-empty environment value.
- Added `IROH_SERVICES_API_SECRET` to GitHub Actions secrets and verified it appears in `gh secret list`.
- Verified Firebase CLI login as `alberto8793@gmail.com`.
- Confirmed the production Firebase project for this rollout is `burnbar` (`246956661961`).
- Confirmed Firebase Remote Config is readable for `burnbar`; the current template is empty.
- Verified Apple signing/notary GitHub Actions secrets exist, and project team ID is `4Y367DF25B`.
- Verified App Store Connect API key ID, issuer ID, and `.p8` body are readable from Firebase Functions Secret Manager.
- Built the monitoring path: scheduled Function `rollupIrohTransportDaily` aggregates `users/{uid}/iroh_audit_events/*` into `ops/iroh_transport_daily_rollups/days/{YYYY-MM-DD}`.
- Added focused monitoring test coverage via `npm run test:iroh-monitoring`.
- Started the Iroh Services hosted relay deploy in the `burnbar` project: US East, v1.0.0-rc.0, $199/month. The dashboard assigned `https://use1-1.relay.alberto8793.burnbar.iroh.link/` and now reports status `running`.
- Documented credential locations, rotation, and telemetry gates in `docs/runbooks/iroh-secrets.md`.

Blocked / pending:
- Wire dev builds to the hosted relay only after Phase C's real Mac to iOS iroh round trip is green on the default/public relay path.
- Publish the hosted relay URL to Firebase Remote Config only after Phase C dev validation and Phase D approval gates.
- Deploy the new monitoring Function only in Phase D after dry-run review and explicit production deploy approval.

## 2026-05-15 — Phase C dev round-trip coding guardrails

**Gate status:** blocked on production Firestore rules rollout. Coding
guardrails are present, the real Iroh FFI is linked in the local Mac build,
and the next Phase C validation attempt reached Firebase before live rules
rejected the pairing-key write.

Completed:
- Added DEBUG-only assertions on Mac host startup and iOS transport bootstrap
  that flag `LoopbackIrohRelayTransport` when the `OpenBurnBarIrohFFI`
  xcframework is not linked. QA/dev runs must use `IrohXcframeworkTransport`;
  the loopback fallback now requires explicit
  `OPENBURNBAR_ALLOW_IROH_LOOPBACK=1` opt-in.
- Added a DEBUG-only AgentLens command-menu toggle:
  `Debug -> Enable/Disable Hermes iroh Transport`. It also enables the Hermes
  Remote Relay host flag so QA can flip the iroh path without navigating the
  Settings UI.
- Added a DEBUG-only launch override:
  `OPENBURNBAR_ENABLE_IROH_TRANSPORT=1`. This lets physical-device and Mac QA
  opt into the hidden iroh flags from `devicectl` / a clean app launch without
  depending on persisted-default timing.
- Fixed `OpenBurnBarCore/Package.swift` so the optional
  `OpenBurnBarIrohFFI` xcframework is detected from the package directory
  instead of the caller's current working directory. A clean macOS build now
  includes `OpenBurnBarIrohFFI` and links `-lopenburnbar_iroh`.
- Launched a DEBUG macOS app build with
  `OPENBURNBAR_ENABLE_IROH_TRANSPORT=1`; the DEBUG loopback assertion did not
  fire, confirming the app resolved the real Iroh transport path.
- Confirmed the source `firestore.rules` contains the required
  `/users/{uid}/iroh_pairing_keys/{roleId}`,
  `/users/{uid}/iroh_pairing/{connectionId}`, and
  `/users/{uid}/iroh_audit_events/{eventId}` rules.
- Updated `scripts/deploy-iroh-relay.sh --dry-run` to run Firebase's real
  `firestore:rules` dry-run instead of only echoing commands.
- `PROJECT_ID=burnbar ./scripts/deploy-iroh-relay.sh --rules-only --dry-run`
  compiles `firestore.rules` successfully.
- `PROJECT_ID=burnbar ./scripts/deploy-iroh-relay.sh --dry-run` also
  completes the Functions dry-run lane: `npm ci` reports 0 vulnerabilities and
  `npm run build` succeeds, and the helper now scopes any real Functions deploy
  to `functions:rollupIrohTransportDaily` by default instead of deploying every
  function. The local shell emits the existing Node 20 vs package Node 22
  engine warning; it does not block the TypeScript build.
- Added a Firestore emulator regression for the Iroh collections. It proves
  same-user writes/reads for pairing keys, pairing records, and append-only
  audit events, plus cross-user denial and secret-field rejection.
  `npm --prefix functions run test:firestore-rules` passes: 17 tests, 0
  failures.
- Re-ran `npm --prefix functions run test:iroh-monitoring`; the TypeScript
  build and `iroh monitoring rollup ok` check pass.
- Hardened `scripts/cutover-n0-hosted-relay.sh publish` so it reads the current
  Firebase Remote Config template through the official REST API, preserves the
  returned ETag with `If-Match`, merges only `hermes_iroh_hosted_relay_url`, and
  supports `--dry-run`. The dry-run command below previews the expected
  parameter and ETag without publishing:
  `PROJECT_ID=burnbar ./scripts/cutover-n0-hosted-relay.sh publish https://use1-1.relay.alberto8793.burnbar.iroh.link/ --dry-run`.
- Verified the rollback dry-run previews clearing the same parameter without
  publishing:
  `PROJECT_ID=burnbar ./scripts/cutover-n0-hosted-relay.sh rollback --dry-run`.

Current blocker:
- The live `burnbar` Firestore rules are behind the source rules. The local
  Mac app currently fails to publish `users/{uid}/iroh_pairing_keys/host` with
  `Missing or insufficient permissions`, and logs
  `hermes_iroh_relay_start_failed`. A production rules-only deploy is required
  before real Mac to iOS iroh round-trip validation can continue.
- 2026-05-16 live readback: Firebase Rules REST reports
  `projects/burnbar/releases/cloud.firestore` on ruleset
  `projects/burnbar/rulesets/dc7a3762-e566-40a5-be98-9cd14329e25d`
  (`updateTime` `2026-05-15T07:23:45.040464Z`). Fetching that ruleset and
  searching for `iroh_pairing`, `iroh_pairing_keys`, and `iroh_audit_events`
  returns zero matches, while the source `firestore.rules` contains all three
  collection rules.
- Firebase Remote Config has not been published, and the hosted relay URL has
  not been cut over to production clients.

Pending:
- Deploy the Firestore rules update to `burnbar` after explicit production
  rules-only deploy approval.
- Re-launch the dev Mac and iOS/iPadOS device as the same Firebase user after
  live rules accept the iroh pairing collections.
- Capture at least 10 consecutive iroh Hermes chat completions across same-LAN
  and different-network topologies.
- Export the expected `iroh_pairing_published`,
  `iroh_pairing_verified`, `iroh_stream_opened`, and
  `iroh_stream_closed` audit sequences under
  `docs/runbooks/iroh-dev-validation/`.
