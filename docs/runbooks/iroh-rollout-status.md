# Hermes iroh Rollout Status

## 2026-05-15 — Phase A local proof

**Gate status:** local proof green; GitHub workflow rerunning on commit `cb9f865fd`.

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

Notes:
- The generated xcframework is intentionally ignored at `Vendor/OpenBurnBarIroh.xcframework/` because the local artifact is 442 MB; CI and release lanes should regenerate/upload it rather than commit it.
- `OpenBurnBarCore/Package.swift` conditionally wires the UniFFI binary target only when the xcframework exists, so normal app CI can still compile the relay package without the binary artifact.
- The iOS adapter now has its own Keychain-backed `IrohRelayKeyStore` and Firestore audit logger; the audit protocol and event enums live in the shared relay package.

Next action:
- Watch the latest GitHub checks. Phase A is not complete until the `OpenBurnBarIroh xcframework` workflow and PR harness are green on commit `cb9f865fd`.

## 2026-05-15 — Phase B infrastructure wiring

**Gate status:** in progress.

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
