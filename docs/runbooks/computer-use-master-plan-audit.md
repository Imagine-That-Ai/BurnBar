# Computer Use master-plan implementation audit

**Audit date:** 2026-05-17T23:13:41Z
**Plan audited:** `plans/2026-05-16-computer-use-master-plan.md`
**Original Claude session:** `~/.claude/projects/-Users-albertonunez-Documents-Windsurf-BurnBar/fc132f73-a087-4fcd-8e79-e08f686bd562.jsonl`
**Resume:** `claude --resume fc132f73-a087-4fcd-8e79-e08f686bd562`

## Executive verdict

**Not launch complete.** The implementation now has a real tested substrate, current-checkout Mac and iOS app-target builds pass with the Computer Use code, the current mobile app installs and launches on Alberto's physical iPhone, Android reducer/control tests pass, the browser bridge smoke, deterministic local 5-scenario Playwright suite, and Phase 9 plan-shape browser suite pass against real Chromium, and the core safety primitives exist. The implementation does **not** satisfy the master plan's launch gates yet because several required device, soak, App Store, notarization, and production audit-export requirements are still missing or only partially implemented.

## Current verified evidence

Commands run from the current checkout, not from the old `build/DerivedData-claude-quota-live` app:

| Check | Result |
|---|---|
| `swift test --package-path OpenBurnBarCore --filter OpenBurnBarComputerUseCoreTests` | 84 tests, 0 failures |
| `swift test --package-path OpenBurnBarCore --filter ComputerUseAuditChainTests` | 8 tests, 0 failures; includes 100-entry valid-chain validation, exact-index tamper detection at every entry, and entry-index gap detection |
| `swift test --package-path OpenBurnBarCore --filter ComputerUsePhoneControlSignerTests` | 15 tests, 0 failures |
| `swift test --package-path OpenBurnBarCore --filter 'MacInputCoreTests|ComputerUsePhoneControlSignerTests'` | 26 tests, 0 failures |
| `swift test --package-path OpenBurnBarCore --filter ComputerUseAuditExportWriterTests` | 6 tests, 0 failures |
| `swift test --package-path OpenBurnBarDaemon --filter ComputerUseRunCoordinatorTests` | 14 tests, 0 failures; browser approval requests now include pre-action PNG evidence fields captured from Playwright before the action is approved |
| `swift test --package-path OpenBurnBarDaemon --filter 'ComputerUseRunCoordinatorPlaywrightScenarioTests\|OpenBurnBarPlaywrightDriverTests\|BurnBarBrowserToolServiceComputerUseTests\|ComputerUseRunCoordinatorTests'` | 19 tests, 2 skipped, 0 failures; opt-in real-Playwright scenarios are compiled but skipped by default |
| `RUN_COMPUTER_USE_PLAYWRIGHT_SCENARIOS=1 swift test --package-path OpenBurnBarDaemon --filter ComputerUseRunCoordinatorPlaywrightScenarioTests` | 2 tests, 0 failures; launches production Playwright bridge/Chromium through `ComputerUseRunCoordinator`; Step mode executes all 7 browser tool kinds with 7 explicit approvals + 7 audit entries, Trusted mode executes the same flow with 0 approvals + 7 `trusted_scope` audit entries |
| `cd functions && npx tsc --noEmit` | exit 0 |
| `cd functions && npm run build && node scripts/test-computer-use-opentimestamps.mjs` | exit 0 |
| `cd functions && npm install && npm run build` after adding `ComputerUsePhoneAuthorityDoc` | exit 0 |
| `cd firestore-rules-tests && firebase emulators:exec --only firestore --project burnbar-test 'node computer-use.test.js'` | 12/12 cases passed, including phone-control authority gating on trusted escrow device + active iroh pairing record |
| `cd android && ./gradlew :app:testDebugUnitTest --tests '*ComputerUse*' --no-daemon` | build successful |
| `scripts/install-playwright.sh` | exit 0; installed pinned Playwright 1.49.1 Chromium/headless shell |
| `bash scripts/test-computer-use-loopback.sh` | initially failed because the pinned Playwright headless shell cache was missing; after `scripts/install-playwright.sh`, exit 0 with `goto`, `current_url`, `shutdown` all OK |
| `node scripts/test-computer-use-browser-scenarios.mjs --runs 5` | exit 0; 25/25 deterministic local-browser scenarios passed through the production bridge, 96 RPCs, RPC p95 41 ms; covers goto/current title/current URL/extract/fill/click/select/key/coordinate click/screenshot |
| `node scripts/test-computer-use-browser-scenarios.mjs --runs 5 --scenario-set phase9-plan` | exit 0; 25/25 Phase 9 plan-shape scenarios passed through the production bridge, 91 RPCs, RPC p95 500 ms; covers Wikipedia search, GitHub repo navigation, form fill, multi-page flow, and error recovery |
| `xcodebuild -scheme OpenBurnBar ... -derivedDataPath build/DerivedData-cu-audit-current build` | exit 0 |
| `xcodebuild -scheme OpenBurnBar ... -derivedDataPath build/DerivedData-cu-targz-current build` | exit 0 |
| `xcodebuild -scheme OpenBurnBar ... -derivedDataPath build/DerivedData-cu-current-normalized build` | exit 0 |
| `xcodebuild -scheme OpenBurnBarMobile -destination id=AFB07C15-AD18-5EFA-AD1C-CADB4F286797 ... build` | exit 0 |
| `xcodebuild -scheme OpenBurnBarMobile ... -derivedDataPath build/DerivedData-cu-phone-hash-ios-fix build` | exit 0 after adding the missing `.deepSeek` provider setup guide |
| `xcodebuild -scheme OpenBurnBarMobile ... -derivedDataPath build/DerivedData-cu-current-audit-ios-buffer2 build` | exit 0 after changing Computer Use control stream classification to `control.input` and clearing the `AgentWatchView.swift` sample-buffer concurrency warning |
| `xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS,arch=arm64' -configuration Debug -derivedDataPath /tmp/DerivedData-cu-current-audit-mac-runtime -quiet build` | exit 0 from current checkout after fixing runtime dispatcher ownership; no `ComputerUseSettingsView.swift` error |
| `xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobile -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -configuration Debug -derivedDataPath /tmp/DerivedData-cu-current-audit-ios-sim-runtime -quiet build` | exit 0 from current checkout; the named `iPhone 17 Pro Max` simulator is not installed, so this used the generic simulator destination |
| `xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobile -sdk iphonesimulator -destination 'generic/platform=iOS Simulator' -configuration Debug -derivedDataPath /tmp/DerivedData-cu-current-audit-ios-sim-runtime -quiet build-for-testing` | exit 0; compiles the mobile test bundle containing Agent Watch phone-control sender coverage |
| `xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS,arch=arm64' -configuration Debug -derivedDataPath /tmp/DerivedData-cu-current-audit-mac-runtime -only-testing:OpenBurnBarTests/ProviderQuotaServiceTests -quiet test` | exit 0 |
| `xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS,arch=arm64' -configuration Debug -derivedDataPath /tmp/DerivedData-cu-current-audit-mac-runtime -only-testing:OpenBurnBarTests/PhoneControlReceiverTests -quiet test` | exit 0 |
| `xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS,arch=arm64' -configuration Debug -derivedDataPath /tmp/DerivedData-cu-phone-loopback -only-testing:OpenBurnBarTests/PhoneControlReceiverTests -quiet test` | exit 0 after registering missing current-tree daemon Droid sources in Xcode; covers `control.classify` authority fetch followed by signed phone `.panic` halting the active session |
| `xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS,arch=arm64' -configuration Debug -derivedDataPath /tmp/DerivedData-cu-phone-stream -only-testing:OpenBurnBarTests/PhoneControlReceiverTests -quiet test` | exit 0; adds stream-level `IrohRelayRequestHandler.serve()` coverage for `control.classify` + signed `control.input.intent` routing into the active coordinator |
| `xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS,arch=arm64' -configuration Debug -derivedDataPath /tmp/DerivedData-cu-mas-guard-flags OTHER_SWIFT_FLAGS='$(inherited) -D DISTRIBUTION_MAS' -quiet build` | exit 0; proves the MAS-style `DISTRIBUTION_MAS` compile-out build path still compiles |
| `xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobile -destination id=AFB07C15-AD18-5EFA-AD1C-CADB4F286797 -configuration Debug -derivedDataPath /tmp/DerivedData-cu-ios-device -allowProvisioningUpdates -quiet build` | exit 0 from current checkout on Alberto's physical iPhone 17 Pro Max |
| `xcrun devicectl device install app --device AFB07C15-AD18-5EFA-AD1C-CADB4F286797 /tmp/DerivedData-cu-ios-device/Build/Products/Debug-iphoneos/OpenBurnBarMobile.app` | installed current-checkout `com.openburnbar.app` on the physical iPhone |
| `xcrun devicectl device process launch --device AFB07C15-AD18-5EFA-AD1C-CADB4F286797 com.openburnbar.app` | launched current-checkout app on the physical iPhone |
| `xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobile -destination id=AFB07C15-AD18-5EFA-AD1C-CADB4F286797 -configuration Debug -derivedDataPath /tmp/DerivedData-cu-ios-device-plugged -allowProvisioningUpdates -quiet build` | exit 0 from current checkout after the phone was plugged back in; Xcode emitted existing Swift 6 concurrency warnings and passcode-protected `notification_proxy` warnings, but the build succeeded |
| `xcrun devicectl device install app --device AFB07C15-AD18-5EFA-AD1C-CADB4F286797 /tmp/DerivedData-cu-ios-device-plugged/Build/Products/Debug-iphoneos/OpenBurnBarMobile.app` | installed current-checkout `com.openburnbar.app` on the physical iPhone |
| `xcrun devicectl device process launch --device AFB07C15-AD18-5EFA-AD1C-CADB4F286797 com.openburnbar.app` | launched the freshly installed current-checkout app on the physical iPhone |
| `xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS,arch=arm64' -configuration Debug -derivedDataPath /tmp/DerivedData-cu-approval-evidence-mac4 -quiet build` | exit 0 after fixing the current-tree relay switch exhaustiveness for Mercury mirror/presence frames; no `ComputerUseSettingsView.swift` error |
| `xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobile -destination id=AFB07C15-AD18-5EFA-AD1C-CADB4F286797 -configuration Debug -derivedDataPath /tmp/DerivedData-cu-approval-evidence-ios -allowProvisioningUpdates -quiet build` | exit 0 from current checkout on the plugged-in physical iPhone 17 Pro Max |
| `xcrun devicectl device install app --device AFB07C15-AD18-5EFA-AD1C-CADB4F286797 /tmp/DerivedData-cu-approval-evidence-ios/Build/Products/Debug-iphoneos/OpenBurnBarMobile.app` | installed current-checkout `com.openburnbar.app` on the physical iPhone |
| `xcrun devicectl device process launch --device AFB07C15-AD18-5EFA-AD1C-CADB4F286797 com.openburnbar.app` | launched the freshly installed current-checkout app on the physical iPhone |

The current-checkout mobile app was launched on the physical iPhone during the latest verification pass. The old `build/DerivedData-claude-quota-live` app was not launched.

## Phase-by-phase status

| Phase | Plan requirement | Current status | Evidence | Gap |
|---|---|---|---|---|
| 8 Agent Watch | Real Mac agent run mirrors to paired phone with live surface, action overlay, and visual approval row | Partial | `AgentWatchHUDSession`, `AgentWatchActionPublisher`, iOS `AgentWatchReceiver`, `AgentWatchView`, Android reducer/screen exist. iOS view has `AVSampleBufferDisplayLayer` decode path. | No filled Phase 8 device matrix. No 5 consecutive Mac to iPhone LAN/LTE Mail runs. No `iroh_audit_events` export proof. No Android live stream proof. |
| 9 Browser CU | Playwright Chromium driven through approval-gated tools, SKU live, scenario/device gates | Partial | Driver/lifecycle/bridge exist. `OpenBurnBarPlaywrightDriverTests` now covers mock-subprocess JSON-RPC method/parameter mapping for click/fill/goto/key/select/screenshot/extract and fixed the driver lifecycle so a subprocess exit drains stdout before failing pending RPCs. `ComputerUseRunCoordinatorTests` now cover browser approval approve, user reject, scope-denied, Trusted-mode allow-rule no-approval, and Step-mode 10-action burst paths; the tests read generated `chain.jsonl` entries and assert action kind, `approvedBy`, `approvalId`, `denyReason`, `scopeRuleId`, and chain length where applicable. Browser approval requests now capture a Playwright pre-action screenshot before approval and carry optional PNG base64/mime/size/hash fields to `ComputerUseApprovalSheet`; the sheet decodes those fields when daemon polling has no direct screenshot `Data`. `ComputerUseRunCoordinatorPlaywrightScenarioTests` now provide opt-in real-Playwright coordinator coverage for all 7 browser tool kinds in Step and Trusted modes, with approval-count and audit-chain-length assertions. Loopback smoke passes after `scripts/install-playwright.sh`. `scripts/test-computer-use-browser-scenarios.mjs --runs 5` drives real Playwright Chromium through 5 deterministic local scenarios x 5 runs, covering goto/current title/current URL/extract/fill/click/select/key/coordinate click/screenshot with 25/25 passes, 96 RPCs, and RPC p95 41 ms. `scripts/test-computer-use-browser-scenarios.mjs --runs 5 --scenario-set phase9-plan` now covers the plan-shape scenario set: Wikipedia search, GitHub repo navigation, form fill, multi-page flow, and error recovery with 25/25 passes, 91 RPCs, and RPC p95 500 ms. Daemon coordinator tests pass. The CI workflow runs the loopback smoke and deterministic local browser scenario suite; the public-web Phase 9 plan-shape suite remains manual because Wikipedia/GitHub availability should not make PR CI flaky. | Missing: 50 runs per device, a captured running-app approval-sheet screenshot/manual visual proof, audit-chain validation on every browser scenario run, 100 TestFlight users, App Store SKU live/accepted, and App Store resubmission acceptance. |
| 10 Trust, scopes, audit | Manual/Step/Trusted, scope matcher, deny registry, audit chain, Step burst 10 actions or 30s | Mostly code-complete, not rollout-complete | Core tests pass. Step burst is implemented in `ComputerUseRunCoordinator` and now covered for both Mac input and browser actions; browser Step mode runs 10 actions from one approval and writes 10 audit-chain entries with the same approval id. Browser approval requests now include pre-action PNG evidence for Manual/Step approval sheets. Real-Playwright Step-mode coordinator proof now runs all 7 browser tool kinds with 7 explicit approvals and 7 audit entries. Trusted browser allow-rule dispatch is covered without approval and records `approvedBy = trusted_scope`; real-Playwright Trusted-mode proof runs all 7 browser tool kinds with 0 approvals and 7 trusted-scope audit entries. Trusted-scope action budgets are now enforced by the matcher and counted by the Mac coordinator after trusted-scope execution. `ComputerUseAuditChainTests` now prove 100-entry chain validation, exact-index tamper detection at every entry including the terminal head-hash case, and entry-index gap detection. | Remaining: captured running-app approval-sheet screenshot/manual visual proof and 7-day soak with zero unintended Trusted-mode escapes. |
| 11 Mac System CU | CGEvent + AX, setup flow, MAS compile-out, direct-download notarized build, device scenarios | Partial | `MacInputController`, `MacAccessibilityInspector`, deny-region classifier, `MacActionDispatcher`, setup wizard, and MAS guards exist. Mac build passes. Prior local CGEvent smoke reportedly posted a click. App-owned sessions are now owned by `ComputerUseRuntimeController`, which attaches the coordinator's control dispatcher to `HermesRelayHostService`, starts panic monitoring, and feeds `ComputerUseSettingsView`. Daemon-owned sessions now have an installed global panic hotkey path through `ComputerUseDaemonApprovalPresenter` + `sessionId = "*"` daemon halt. MAS compile-out build proof passes with `-D DISTRIBUTION_MAS`. | Daemon RPC system mode fails closed with `accessibilityTrusted: false`; Path C is therefore currently app-owned rather than daemon-owned. No Calculator 50/50, TextEdit 50/50, deny-region 12/12 device proof, notarized Developer ID build, or `spctl --assess`. |
| 12 Phone controller | Signed phone intents, real `control.input`, approval from phone, p95 latency, replay/tamper chaos | Partial | iOS sender/issuer, Mac receiver/validator, iOS control stream coordinator, approval response path, and 16 phone signer tests exist. Android now has `PhoneControlSigner.kt`, which mirrors the Swift authority-free hash/sign/verify contract with Tink Ed25519, `PhoneControlSender.kt`, which emits signed `control.input.intent` frames, and `PhoneControlAuthorityPublisher.kt`, which publishes the same pairing-rooted controller public-key doc shape as iOS while `PhoneControlSigningKeyStore` wraps the Ed25519 seed with Android Keystore AES-GCM. The Android relay model now includes Computer Use `control.*` frame types and a codec test round-trips a signed input frame shape through the real length-prefixed JSON codec. Real `control.input` signing now hashes the action fields without the attached authority envelope, and tests prove attached-authority round trip plus tamper rejection. Normalized phone coordinate translation now lives in `MacInputCore` and has 5 direct tests. The long-lived stream now classifies as `control.input`, the phone takeover UI exposes tap/type/shortcut controls, and the watch surface now converts tap and drag-scroll gestures into signed `control.input` intents. Phone-control authority is now written under `iroh_pairing/{connectionId}/controllers/{peerNodeId}` and Mac fetches that key from Firestore instead of accepting in-band key material; rules require a trusted escrow device and existing pairing record. The app startup path now installs the Computer Use `control.*` dispatcher on the live `HermesRelayHostService` rather than a disconnected `CloudSyncService`. Scroll is now a first-class Mac input action instead of degrading to click. Mac loopback proof: `PhoneControlReceiverTests` now cover `control.classify` registering/fetching the pairing-rooted authority, then a signed phone `.panic` intent halting the active session with no denied frames; a stronger stream-level test drives `IrohRelayRequestHandler.serve()` with a fake `IrohRelayStream` carrying `control.classify` and signed `control.input.intent`, proving the host stream loop routes into the active coordinator. Physical iPhone proof: `xcodebuild -scheme OpenBurnBarMobile -destination id=AFB07C15-AD18-5EFA-AD1C-CADB4F286797 build` exit 0, `OpenBurnBarMobileTests/OpenBurnBarMobileTests/testAgentWatchReceiverSendsSignedTapAndScrollIntents` passed on Alberto's iPhone 17 Pro Max with 1/1 tests passing, and the current-checkout `OpenBurnBarMobile.app` installed and launched on the same device. Android proof: `./gradlew :app:testDebugUnitTest --tests 'com.openburnbar.data.computeruse.*' --no-daemon` exit 0 with 19 tests, `./gradlew :openburnbar-iroh-relay:testDebugUnitTest --tests 'com.openburnbar.irohrelay.HermesRealtimeRelayControlFrameTest' --no-daemon` exit 0, `./gradlew :app:assembleDebug --no-daemon` exit 0, and the current-checkout debug APK installed and launched on USB device `SM_S921U`. | There is no live phone-to-Mac signed input loop through a paired iroh session, 100 intents/device, p95 latency, 1000 replay chaos, or 7-day error-rate proof. |
| 13 Polish | Trusted scope library, expiry, signed `tar.gz` audit export with device identity, OpenTimestamps verification | Partial | Scope library and OTS client/archive exist. Export now writes a real `.tar.gz` plus detached Ed25519 signature. The daemon export signer is now Keychain-backed, migrates/removes the previous raw key file, and sidecars include trusted-device metadata plus public-key SHA-256. Settings export now publishes the signer public key under the Mac escrow device, and Firestore rules bind that readback doc to a trusted macOS device with delete disabled and revocation allowed. Tests verify parsing, tamper detection, signature validation, sidecar key-hash validation, trusted-device readback rejection for revoked/mismatched signers, legacy raw-key migration, Firestore readback/revocation rules, and `/usr/bin/tar -tzf` readability. `validateOpenTimestampsProof` now has injectable verifier/head dependencies, stronger behavior tests, cross-checks the submitted head against Firestore, and delegates proof verification to either `OPENBURNBAR_OTS_VERIFY_URL` or local `ots verify`. A Dockerized verifier service now packages the official OpenTimestamps CLI for Cloud Run. | The original phrase "iCloud device certificate" has been amended to OpenBurnBar trusted-device signing identity because this repo has no iCloud-device-certificate API or pattern. Production still needs verifier-service deployment, production `OPENBURNBAR_OTS_VERIFY_URL`, and 10/10 upgraded Bitcoin-header proof evidence. |

## Important implementation mismatches

### Phase 13 signer identity amendment: iCloud certificate replaced with OpenBurnBar trusted-device identity

The master plan originally said Phase 13 export must produce a signed `tar.gz` containing the JSONL chain and screenshots, signed with the user's iCloud device certificate. Repo audit found no `SecIdentity` / `SecCertificate` / iCloud-backed audit signer pattern, and the shipping Developer ID entitlement story is not an iCloud certificate authority. Treating a raw Ed25519 key file as an "iCloud certificate" would be false.

The implementation now uses the real available trust primitive: an OpenBurnBar trusted-device Ed25519 signing identity stored in the local Keychain as `WhenUnlockedThisDeviceOnly`. The daemon migrates the previous raw `audit-export-ed25519.raw` key into Keychain once, removes the raw file after successful migration, and writes signature sidecars with:

- `signerKind = openburnbar_trusted_device`
- `trustRoot = openburnbar-trusted-device-keychain-v1`
- `publicKeyBase64`
- `publicKeySHA256Hex`

The audit verifier now rejects sidecars whose public-key hash no longer matches the included public key. The trusted-device verifier mode also requires a Firestore readback record and rejects revoked or mismatched signer records.

Evidence:
- `plans/2026-05-16-computer-use-master-plan.md:1127`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarComputerUseContracts.swift:190`
- `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/ComputerUseAuditExportWriter.swift`
- `firestore.rules`
- `firestore-rules-tests/computer-use.test.js`
- `AgentLens/Services/ComputerUse/ComputerUseRuntimeController.swift`
- `AgentLens/Views/ComputerUse/ComputerUseSettingsView.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/ComputerUseService.swift:154`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/ComputerUseAuditExportSignerProvider.swift`
- `OpenBurnBarDaemon/Tests/OpenBurnBarDaemonTests/ComputerUseAuditExportSignerProviderTests.swift`

Do not describe this as an Apple/iCloud certificate.

### P1: daemon System-mode route is not real Mac input yet

`ComputerUseService.invoke` builds capability with `accessibilityTrusted: false`, so daemon-routed System-mode input fails closed. The app-owned `ComputerUseSessionCoordinator` uses `inputController.isAccessibilityTrusted()` and can dispatch real CGEvents, but the daemon RPC path is not a real System-mode executor.

Evidence:
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/ComputerUseService.swift:97`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/ComputerUseService.swift:104`
- `AgentLens/Services/ComputerUse/ComputerUseSessionCoordinator.swift:354`
- `AgentLens/Services/ComputerUse/ComputerUseSessionCoordinator.swift:361`
- `AgentLens/Services/ComputerUse/ComputerUseRuntimeController.swift`
- `AgentLens/Services/OpenBurnBarStartupRecovery.swift:264`
- `AgentLens/Views/ComputerUse/ComputerUseSettingsView.swift`

Resolution needed: clarify architecture. If daemon is Browser-only and app owns Path C, docs/contracts should say that. If daemon RPC is intended to execute Path C, it needs a real app bridge for AX trust, scope context, deny regions, and Mac dispatch. Current verified implementation leans app-owned for Path C.

### P1 reduced: OpenTimestamps verifier packaging exists, but production proof remains open

`validateOpenTimestampsProof` is now exported from Cloud Functions. It enforces Firebase Auth/App Check ownership, checks the submitted audit head against `users/{uid}/computer_use_sessions/{sessionId}.auditHeadHashHex`, validates the proof payload shape/size, and verifies through `OPENBURNBAR_OTS_VERIFY_URL` before falling back to local `OPENBURNBAR_OTS_VERIFY_BIN` / `ots`. The Dockerized verifier in `tools/opentimestamps-verifier-service/` packages `opentimestamps-client==0.7.2`; local smoke proved `/healthz` and official `ots` rejection of an invalid proof.

Evidence:
- `functions/src/computerUseOpenTimestamps.ts`
- `functions/src/index.ts`
- `functions/scripts/test-computer-use-opentimestamps.mjs`
- `tools/opentimestamps-verifier-service/`

Resolution needed: deploy the verifier service, set production `OPENBURNBAR_OTS_VERIFY_URL`, then record 10/10 upgraded `.ots` proofs verified against Bitcoin headers.

### P1 reduced: phone-control authority is now rooted in pairing state, but still needs real-device proof

Evidence:
- `OpenBurnBarMobile/Services/ComputerUse/AgentWatchOverlayCoordinator.swift`
- `OpenBurnBarMobile/Services/ComputerUse/PhoneControlAuthorityPublisher.swift`
- `AgentLens/Services/ComputerUse/ComputerUseSessionCoordinator.swift`
- `AgentLens/Services/ComputerUse/PhoneControlAuthorityProvider.swift`
- `AgentLens/Services/ComputerUse/PhoneControlAuthorityValidator.swift`
- `firestore.rules`
- `firestore-rules-tests/computer-use.test.js`

Current state: the phone publishes its control Ed25519 public key under the active signed iroh pairing document at `users/{uid}/iroh_pairing/{connectionId}/controllers/{peerNodeId}`. The Mac uses `authorityPeerNodeId` from `control.classify` only as an identifier, fetches the public key from Firestore, and rejects missing/malformed/stale/untrusted-device authority records. Firestore rules require an existing iroh pairing record and `escrow_devices/{deviceId}.trustState == "trusted"` on iOS/iPadOS/Android.

Remaining proof needed: run a real paired phone-to-Mac signed input loop and replay/tamper chaos suite on physical devices.

### P1: rollout docs are checklists, not proof

`docs/runbooks/computer-use-device-matrix/phase-9.md`, `phase-11.md`, and `phase-12.md` are manual checklists. They do not record completed device runs, pass/fail rows, dates, or evidence links. There is no Phase 8 device-matrix result file in this audit.

Resolution needed: convert device matrix files into result logs before flag flip. Record exact device, OS, network, build, run count, latency p95, failures, and evidence path.

### P1: App Store and distribution gates remain external

The plan requires live/accepted SKUs, App Store resubmission acceptance, direct-download notarization, and `spctl --assess`. The codebase has StoreKit/ASC tooling and status docs, but this audit did not find production-live SKU approval, accepted resubmission, or notarized direct-download proof.

Resolution needed: complete App Store Connect review and direct-download notarization outside code, then attach evidence.

## Current compile-error status

There is no current `ComputerUseSettingsView.swift` compile error in this audit. The current-checkout Mac app target, generic iOS simulator target, and physical iPhone target all build. The latest compile blockers were relay switch-exhaustiveness errors after existing Mercury Phase 8 frame cases (`.mediaMirrorRequest`, `.mediaMirrorAck`, `.mediaPresenceHeartbeat`) were added to `HermesRealtimeRelayFrameType`; `IrohRelayRequestHandler`, `HermesRealtimeRelayHostClient`, `HermesService`, and `HermesIrohRelayTransport` now route or ignore those cases explicitly. Earlier current-tree blockers were unrelated Droid routing files missing from `OpenBurnBar.xcodeproj`: `FactoryDroidProviderExecutor.swift` defines `BurnBarCompositeProviderExecutor`, which `OpenBurnBarRunService` already references, and `FactoryDroidProviderExecutorTests.swift` defines `RecordingFactoryDroidRunner`, which daemon tests already reference. Both are now registered in the daemon source/test targets. Earlier Computer Use compile blockers were `ComputerUseRuntimeController.swift` calling `setComputerUseControlDispatcher` on `CloudSyncService` and the new daemon audit-export signer provider being absent from the Xcode daemon target. The dispatcher belongs to `HermesRelayHostService`, so startup now passes the relay host into the runtime controller and the controller installs the dispatcher there; `ComputerUseAuditExportSignerProvider.swift` is now registered in `OpenBurnBar.xcodeproj`. The follow-up Phase 12 gesture work also compiles in the Mac app target, iOS app target, Mac `PhoneControlReceiverTests`, iOS simulator build-for-testing, and physical iPhone focused test. During the audit-export readback pass, the Mac build exposed one unrelated dirty-tree compile blocker in `ConnectionsViewModel.swift` where new `baseModelID` / `thinkingLevel` fields were not initialized from `ProxyModelRow`; that initializer now sets both to `nil`. Earlier build blockers fixed during this audit included missing `.scroll` switch cases after adding `mac_input_scroll`, two Computer Use warnings (`PhoneControlReceiver` unused validation result and `ComputerUseSessionCoordinator` nonisolated observer removal), and unrelated dirty quota work in `ProviderQuotaService.swift`.

## What is genuinely done

- Shared Computer Use core exists and is tested.
- Browser bridge can currently drive Playwright Chromium in loopback, through a deterministic 5-scenario x 5-run local suite covering navigation, extraction, forms, select controls, keyboard input, coordinate click, and screenshot, through a Phase 9 plan-shape 5-scenario x 5-run public/local suite covering Wikipedia search, GitHub repo navigation, form fill, multi-page flow, and error recovery, and through an opt-in coordinator-level real-Playwright Step/Trusted trust-mode suite with approval-count and audit-chain assertions.
- Current-checkout Mac, iOS simulator, and physical iPhone app targets compile with the Computer Use code; the current mobile app installs and launches on Alberto's physical iPhone 17 Pro Max.
- The Mac target also compiles with `DISTRIBUTION_MAS` injected, proving the MAS guard path is build-clean.
- Android has a tested Agent Watch reducer/surface scaffold, tested Tink Ed25519 phone-control signing semantics, signed `control.input.intent` frame emission, pairing-rooted authority-doc generation, Android Keystore-wrapped signing seed storage, and relay-codec coverage for Computer Use control frames.
- Step-mode burst approval exists and is tested at daemon coordinator level for Mac input and browser actions; browser Step mode now proves 10 actions from one approval with 10 audit-chain entries, plus a real-Playwright all-browser-tool-kind Step scenario with explicit approval counting.
- Approval presenter, approval sheet, daemon browser pre-action PNG evidence, scope rules, audit chain, OTS mock path, phone signing, and panic primitives exist.
- Mac stream-loop coverage now proves `IrohRelayRequestHandler.serve()` forwards `control.classify` and signed `control.input.intent` frames into the active Computer Use coordinator.
- Trusted-scope action budgets are no longer just data-model/test scaffolding; the shared matcher ignores exhausted rules, Trusted browser dispatch skips approval only on an allow rule, and the Mac coordinator increments counts after trusted-scope execution.

## What is not done

- Full plan acceptance gates.
- Real Phase 8 Mac to iPhone/iPad/Android LAN/LTE evidence.
- Phase 9 50-runs-per-device matrix, captured running-app approval-sheet visual proof, audit-chain-per-run proof, and TestFlight/user gates.
- Phase 10 soak and captured running-app approval-sheet visual proof.
- Phase 11 direct-download notarized distribution and 50/50 app scenarios.
- Phase 12 live phone-to-Mac input latency, replay, tamper, and cross-device approval proof through a paired iroh session.
- Phase 12 multi-device matrix proof beyond focused physical iPhone build/install/launch and sender tests.
- Deployed OpenTimestamps verifier service + production `OPENBURNBAR_OTS_VERIFY_URL` evidence.
- OpenTimestamps proof verification against Bitcoin block headers for 10/10 upgraded sessions.

## Recommendation

**Continue hardening. Do not mark the master plan complete.**

Next highest-value verification step is a real paired-device Phase 12 run: phone watches Mac, signs control input, Mac validates the pairing-rooted key, executes tap/type/scroll, and rejects replay/tamper cases. Next highest-value Phase 13 step is deploying the Dockerized OTS verifier service, setting `OPENBURNBAR_OTS_VERIFY_URL` on production Functions, and proving 10/10 upgraded Bitcoin-header validations.
