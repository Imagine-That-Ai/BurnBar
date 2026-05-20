# Computer Use — rollout status

**Owner:** Alberto · **Master plan:** [`plans/2026-05-16-computer-use-master-plan.md`](../../plans/2026-05-16-computer-use-master-plan.md) · **Wire reference:** [`HERMES_COMPUTER_USE.md`](../HERMES_COMPUTER_USE.md)

Phase rollout log. One entry per phase ship — appended-to as flags advance through 5% → 25% → 50% → 100%. Mirrors `media-rollout-status.md`.

---

## Phase 8 — Agent Watch (read-only mirror)

- **Flag:** `computer_use_watch_enabled` · default off
- **Substrate landed (2026-05-17):**
  - `MediaStreamClass` adds `control.surface.frame`, `control.action.log`, `control.input`, `control.approval`
  - `MediaFrame.Flags.hasCursorMetadata = 0x08` (NOT `0x04` — `0x04` is `.muted`)
  - `HermesRealtimeRelayFrameType` adds 6 control cases + `HermesRealtimeRelayControlPayload`
  - `OpenBurnBarComputerUseCore` SwiftPM target (cross-platform shared types)
	  - `OpenBurnBarComputerUseCore` wired into `OpenBurnBar.xcodeproj` for AgentLens (macOS), OpenBurnBarMobile (iOS), and OpenBurnBarDaemon library targets; current Mac app + daemon executable `xcodebuild` proofs are green from `/tmp` DerivedData
	  - `IrohRelayRequestHandler` dispatches control frames via `ControlFrameDispatcher`
- **Implementation status:** Mac now has `AgentWatchHUDSession` + `AgentWatchActionPublisher`; iOS `AgentWatchView` now owns an `AVSampleBufferDisplayLayer` decode path for `MediaFrame` surface frames. Full iroh surface-frame fanout still needs real-device LAN/LTE proof before flag flip.
- **Test coverage:** `swift test --filter OpenBurnBarComputerUseCoreTests` has 88 tests green covering Phase 8 substrate (5 codec-cursor tests in `MediaPacketCodecTests`). `AgentWatchActionPublisherTests` passes in the macOS app test target and covers journal-event to `control.action.log.entry` frame shape, stream class/session routing, summary precedence, status mapping, monotonic entry indexes, and audit metadata preservation. `OpenBurnBarMobileTests/testAgentWatchLoopbackReflectsTenActionLogEntriesWithinTwoHundredMillisecondsEach` passes on Alberto's physical iPhone 17 Pro Max and proves 10 fake agent action-log frames reach the phone-visible `AgentWatchState.actionTimeline` within the 200 ms budget each.
- **Acceptance gate remaining:**
	  - [ ] Mercury Phase 3 ≥ 95% success for the prior 7 days
	  - [ ] 5 consecutive Mac→iPhone "agent triages 3 emails via Mail" runs across LAN + LTE
	  - [ ] TestFlight 5% rollout

## Phase 9 — Browser Computer Use (Manual mode)

- **Flag:** `computer_use_browser_enabled` · default off
- **Code landed (2026-05-17):**
  - 13 new `BurnBarToolKind` cases + 7 new `BurnBarBrowserActionKind` cases
  - `OpenBurnBarPlaywrightDriver` + `OpenBurnBarPlaywrightLifecycle` (auto-install pinned `playwright@1.49.1`); driver stdout reading now runs outside actor isolation, and subprocess termination drains stdout before failing pending RPCs
  - Node.js bridge script `openburnbar-playwright-bridge.js`
	  - `ComputerUseRunCoordinator` daemon-side orchestrator
	  - `BurnBarComputerUseContracts.swift` socket-RPC contracts
	  - `BurnBarAgentLoopActionKind` now accepts browser actions; daemon browser RPC dispatches Playwright `click/fill/goto/key/select/screenshot/extract` instead of rejecting them
	  - `ComputerUseApprovalSheet` SwiftUI surface; daemon browser approvals now carry optional pre-action PNG evidence from Playwright so the global approval presenter can render the thumbnail instead of a text-only placeholder
	  - `scripts/install-playwright.sh` + `scripts/test-computer-use-loopback.sh` + `scripts/test-computer-use-browser-scenarios.mjs` + `.github/workflows/computer-use-loopback-test.yml`
- **Test coverage:** Daemon `swift build` green; `OpenBurnBarPlaywrightDriverTests` proves mock-subprocess JSON-RPC method/parameter mapping for click/fill/goto/key/select/screenshot/extract and covers the subprocess-exit drain path; `BurnBarBrowserToolServiceComputerUseTests` proves Playwright interactive dispatch and non-Playwright fail-closed behavior; `ComputerUseRunCoordinatorTests` covers browser approval approve/reject/scope-denied paths, Trusted-mode allow-rule dispatch without an approval sheet, Step-mode 10-action browser burst execution from one approval, and `ChaosBrowserActionTimeout` where a hung Playwright RPC fails in under 10 seconds, stops the bridge process, and records a failure audit entry. Those tests decode the resulting audit-chain entries to prove `approvedBy`, `approvalId`, `denyReason`, `scopeRuleId`, action kind, and chain length, and assert Manual/Step browser approval requests include pre-action PNG evidence fields. `ComputerUseRunCoordinatorPlaywrightScenarioTests` is opt-in and, with `RUN_COMPUTER_USE_PLAYWRIGHT_SCENARIOS=1`, drives real Playwright Chromium through the coordinator in Step and Trusted modes across all seven browser tool kinds; Step records 7 explicit approvals + 7 audit entries, Trusted records 0 approvals + 7 `trusted_scope` audit entries, and each run now validates `chain.jsonl` through `ComputerUseAuditChain.validate(... expectedHeadHashHex:)`. Phase 9 local 50-run gate: `RUN_COMPUTER_USE_PLAYWRIGHT_50_RUN_GATE=1 swift test --package-path OpenBurnBarDaemon --filter ComputerUseRunCoordinatorPlaywrightScenarioTests/testFiftyLocalBrowserScenariosValidateAuditChainEveryRun` passed 50/50 real Playwright coordinator sessions, 350/350 executed responses, and 350/350 validated audit entries. Real Playwright Chromium proof: `node scripts/test-computer-use-browser-scenarios.mjs --runs 5` passed 25/25 deterministic local-browser scenarios across 96 bridge RPCs, exercising goto/current title/current URL/extract/fill/click/select/key/coordinate click/screenshot with RPC p95 41 ms. Phase 9 plan-shape proof: `node scripts/test-computer-use-browser-scenarios.mjs --runs 5 --scenario-set phase9-plan` passed 25/25 scenarios across 91 bridge RPCs, covering Wikipedia search, GitHub repo navigation, form fill, multi-page flow, and error recovery with RPC p95 500 ms.
- **Acceptance gate remaining:**
	  - [ ] `hosted_computer_use_sync` + `burnbar_pro_max` SKUs accepted by App Store review
	  - [ ] `NSAppleEventsUsageDescription` re-submission accepted
	  - [x] Mac/local coordinator 50-run row with audit-chain validation on every run
	  - [ ] Remaining per-device/browser rollout rows beyond the Mac/local coordinator proof
	  - [ ] 100 TestFlight users at ≥ 95% scripted-scenario completion

## Phase 10 — Trust modes + scope rules + audit chain

- **Flag:** `computer_use_trust_modes_enabled` · default off
- **Code landed (2026-05-17):**
  - `ComputerUseTrustMode` + `ComputerUseScopeRule` + `ComputerUseScopeMatcher`
  - `ComputerUseDenyRegistry` with 12 built-in deny entries
  - `ComputerUseAuditChain` + `ComputerUseAuditLogger` + `ComputerUseAuditHasher` (SHA-256, BLAKE3-swappable)
  - `ComputerUseSessionPanel` Mac UI surface
  - `ComputerUseApprovalSheet` step-mode burst approval toggle
- **Test coverage:** 16 ScopeMatcher tests · 8 AuditChain tests including 100-entry valid-chain validation, exact-index tamper detection at every entry, and entry-index gap detection · 15 CapabilityGate tests · 6 AuditExport tests · `ComputerUseRunCoordinatorTests` proves Trusted-mode browser allow-rule dispatch skips approval and records `approvedBy = trusted_scope`, and Step-mode browser burst runs 10 actions from one approval with 10 audit-chain entries · opt-in real-Playwright coordinator scenarios prove Step and Trusted modes against Chromium with approval-count and audit-chain-length assertions.
- **Acceptance gate remaining:**
  - [ ] 7-day internal-user soak with zero unintended Trusted-mode escapes

## Phase 11 — Mac System Computer Use

- **Flag:** `computer_use_system_enabled` · default off
- **Code landed (2026-05-17):**
  - `MacInputController` (CGEvent wrapper, display-bounds gated, delegates to `MacInputCore`)
  - `MacAccessibilityInspector` (AX role/subrole + deny-region matcher)
  - `ComputerUseRuntimeController` owns app-side Path C sessions, attaches the active coordinator to `HermesRelayHostService`, starts panic monitoring, and backs `ComputerUseSettingsView`
  - `ComputerUseService` daemon facade rejects app-owned `system` / `agent_watch` starts early with `unsupportedDaemonMode`; daemon-owned sessions are Browser/Path B only
  - `ComputerUsePanicHaltCoordinator` (hotkey + auth-gate + remote-config kill paths); daemon-wide panic accepts `sessionId = "*"` and the app startup presenter installs the hotkey coordinator for daemon-owned sessions
  - `ComputerUseSetupWizard` Accessibility-permission flow
  - `#if !DISTRIBUTION_MAS` compile-out applied to MacInputController, MacAccessibilityInspector, ComputerUseSetupWizard, PhoneControlReceiver
- **Test coverage:** 9 MacInputCore tests (virtual-key map, modifier flags, display-bounds containment) · `ComputerUseRunCoordinatorTests` proves daemon `ComputerUseService` rejects app-owned Path A/C modes at session start · `MacComputerUseDenyRegionsTests` proves 12/12 sensitive AX/bundle-title cases are denied and 3 benign elements are allowed · Calculator loopback proof: `tools/CUClickSmoke --scenario calculator --runs 50` passed 50/50 via CGEvent typing + AX result readback (`p95=157.25 ms`) · TextEdit loopback proof: `tools/CUClickSmoke --scenario textedit --runs 50` passed 50/50 via CGEvent compose + bold-format + save + RTF readback (`p95=1176.51 ms`) · MAS compile-out proof: `xcodebuild ... OTHER_SWIFT_FLAGS='$(inherited) -D DISTRIBUTION_MAS' build` exit 0
- **Acceptance gate remaining:**
  - [ ] ≥ 14-day Phase 9 soak with ≥ 95% success rate
  - [x] Calculator 50/50 loopback
  - [x] TextEdit 50/50 loopback
  - [x] Deny-region 12/12 proof
  - [x] MAS `DISTRIBUTION_MAS` compile-out build proof
  - [ ] Direct-download notarized build verified via `spctl --assess`

## Phase 12 — Phone-as-controller

- **Flag:** `computer_use_phone_control_enabled` · default off
- **Code landed (2026-05-17):**
  - `ComputerUsePhoneControlSigner` (Ed25519 + canonical-JSON intent hashing; `control.input` hashes exclude the attached authority envelope)
  - iOS `PhoneControlAuthorityIssuer` + `PhoneControlSender` (signed envelope → `control.input` frame → iroh write; long-lived stream now classifies as `control.input`)
  - iOS `PhoneControlAuthorityPublisher` writes the phone control public key to `iroh_pairing/{connectionId}/controllers/{peerNodeId}` before stream classify; Mac `PhoneControlAuthorityProvider` fetches that key from Firestore instead of trusting in-band key material.
  - Mac `PhoneControlAuthorityValidator` + `PhoneControlReceiver` (decode → validate → translate normalized intent → dispatch via run coordinator; emits `control.denied` on validation failure)
  - Mac startup installs the Computer Use `control.*` dispatcher on the live `HermesRelayHostService` so `control.input` frames reach the app-owned coordinator.
  - `AgentWatchView` converts phone taps to signed `.tap` intents and drag gestures to signed `.scroll` intents; `PhoneControlOptionSheet` sends type text, Return, Escape, and Command-L shortcuts.
  - Android relay wire model now includes Computer Use `control.*` frame types + `control` payload. Android `PhoneControlSigner` mirrors the Swift authority contract with Tink Ed25519, authority-free canonical JSON hashing, replay/freshness/tamper verification, and Swift Date reference-second conversion for Mac-bound frames; `PhoneControlSender` emits signed `control.input.intent` frames through an injected frame sink.
  - Android `PhoneControlAuthorityPublisher` writes the phone control public key to `iroh_pairing/{connectionId}/controllers/{peerNodeId}` with the same schema/rules shape as iOS, and `PhoneControlSigningKeyStore` persists the Ed25519 seed wrapped by Android Keystore AES-GCM. Android Keystore encryption now lets the platform generate the AES-GCM IV and persists `cipher.iv`, matching Android's randomized-encryption requirement; the Mercury iroh blob key store uses the same corrected pattern.
  - Android `IrohJniTransport.start()` retries transient home-relay bootstrap failures before surfacing an error, covering mobile network timing where the native endpoint does not select a home relay within the first 10 seconds.
  - Phone scroll maps to first-class `mac_input_scroll` / `MacInputAction.Kind.scroll` and posts a real CGEvent scroll instead of degrading to click
  - Trust-mode downgrade-from-phone wired through `AgentWatchState.setTrustMode` (Mac coordinator subscribes)
- **Test coverage:** 16 Swift PhoneControlSigner golden-case tests proving signature, replay, freshness, intent-hash, peer-key, payload-stability, attached-authority, drag endpoint hash coverage, and tamper semantics · 19 Android Computer Use JVM tests covering watch reducer, Tink signing, canonical JSON, big-endian payload, replay/freshness/tamper/foreign-key rejection, drag endpoint hash coverage, Swift Date compatibility, signed `control.input.intent` frame emission, per-peer counter increment, missing-key failure, and authority-doc Firestore map shape/peer-id validation · Android relay codec test round-trips a `control.input.intent` frame through the real length-prefixed JSON codec · Android iroh relay test proves transient home-relay bootstrap retry behavior · 5 MacInputCore normalized-coordinate tests · `PhoneControlReceiverTests` prove signed scroll dispatch + malformed-coordinate denial, coordinator-level `control.classify` authority fetch followed by signed phone `.panic`, stream-level `IrohRelayRequestHandler.serve()` routing of `control.classify` + signed `control.input.intent` into the active coordinator, and receiver-level replay chaos where 1 valid signed tap dispatches once and 1,000 duplicate envelopes are rejected as `counterReplay` (`/tmp/cu-phone-replay-chaos-fresh.log`) · iOS build-for-testing covers `AgentWatchReceiver` signed tap/scroll sender path · physical iPhone 17 Pro Max run passed `OpenBurnBarMobileTests/OpenBurnBarMobileTests/testAgentWatchReceiverSendsSignedTapAndScrollIntents` (1/1) · clean `/tmp/DerivedData-cu-iphone-current` current-checkout `OpenBurnBarMobile.app` built, installed, and launched on the physical iPhone 17 Pro Max · physical Android live paired-device proof sent signed tap/scroll/panic over iroh to the Mac; after Mac restart/TCC reset and the phone-approval gate fix, the current proof app logged `mac_accessibility_trusted`, executed `mac_input_click` and `mac_input_scroll` with audit entries `0` and `1`, and received phone panic (`/tmp/cu-live-proof-android-executed.jsonl`, `/tmp/cu-live-computer-use-proof-executed.jsonl`) · physical Android 100-intent latency proof sent 100 signed tap/scroll intents, with Mac receiving 100/100 and dispatching 100/100 executed; clock-safe Mac receive-to-dispatch latency was p50 152.5 ms, p95 162.0 ms, max 200 ms (`/tmp/cu-live-latency-android.jsonl`, `/tmp/cu-live-latency-mac.jsonl`, `/tmp/cu-live-latency-summary.json`) · physical Android live replay/tamper chaos proof sent 1 valid tap + 1,000 duplicate replay frames + 100 tampered frames over the paired iroh stream; Mac received 1,101 input frames, executed only the valid tap, denied 1,100 bad frames, and executed 0 bad frames; a focused tamper pass proved 100/100 `signature_failure` denials (`/tmp/cu-live-chaos-android.jsonl`, `/tmp/cu-live-chaos-mac.jsonl`, `/tmp/cu-live-tamper-step-android.jsonl`, `/tmp/cu-live-tamper-step-mac.jsonl`, `/tmp/cu-live-chaos-summary.json`) · Firestore emulator covers trusted-device + active-pairing gating for phone authorities
- **2026-05-18 visible paired-Mac fix:** Android Hermes Square now refreshes relay connections while the screen is open, resolves persisted `device://paired-mac/*` pins before relay hydration, and force-pins the Mac tile ahead of a full 12-slot grid even when the paired relay is offline/pending. iPhone Hermes Square now keys the Mac tile from the real relay ID, refreshes relay state before booting Mercury, passes the real relay ID to Mercury Live, and restarts stale/failed Mercury control-stream coordinators instead of reusing a stream for the wrong Mac connection. Verification: `./gradlew :app:compileDebugKotlin :app:testDebugUnitTest --no-daemon` passed, `swift test --package-path OpenBurnBarCore --filter HermesSquarePinnedGridTests` passed 6/6, `xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobile -destination 'id=00008150-00180C661EF0401C' -configuration Debug -derivedDataPath /tmp/DerivedData-cu-mercury-real-relay -quiet build` passed, current Android APK installed on Samsung `R3CXB0CNS0J`, and current iPhone app installed on device `00008150-00180C661EF0401C`. Follow-up hardening on the same day added offline/pending paired-relay pinning plus connection-matched Mercury coordinator restart; focused Android test and iPhone physical build/install passed from `/tmp/DerivedData-cu-mercury-current`. Follow-up live-tap hardening adds a retained Mac `NSPanel` presenter for Mercury mirror approvals, iPhone "Waiting for Mac..." send feedback, and Android paired-Mac tile navigation to `computer_use`; Mac + iPhone current-checkout builds passed, Android paired-Mac tests and `:app:assembleDebug` passed, and fresh Mac/iPhone/Android builds were launched/installed. Follow-up mirror-accept hardening wires `MercuryRouter` to a real `MediaStreamSink` over the paired iOS `media.control` iroh stream, sends encoded `MediaFrame` packets as `media.stream.frame`, and decodes them into the iPhone full-screen screen-share viewer after an accepted ack; fresh macOS and iPhone builds passed and were relaunched/installed from current DerivedData. Follow-up Mac tray hardening adds a current-checkout `NSStatusItem`/`NSMenu` dashboard fallback, duplicate-launch handoff, and `LSMultipleInstancesProhibited`; `open -b com.openburnbar.app openburnbar://dashboard` presents an on-screen dashboard window from `~/Applications/OpenBurnBar.app`, with `/v1/models` reporting 50 models and 0 duplicate IDs. Android Ask-to-Mirror now has first-class `media.mirror.request` / `media.mirror.ack` relay frames, a paired-Mac controls screen, and request/ack unit coverage; focused relay/app tests, `:app:assembleDebug`, and install to Samsung `R3CXB0CNS0J` passed. Android media-control presence now emits `media.presence.heartbeat` every 60s with peer identity and mirror/file-transfer capabilities, the app registers a real iroh-blobs `AndroidFileTransferService` at startup, and paired-Mac Send File now uses the Android document picker plus the persistent `media.control` stream; focused `MediaControlStreamCoordinatorTest`, `:app:compileDebugKotlin`, and `:app:assembleDebug` passed after these additions. Android Call Mac now sends first-class `media.call.invite` frames over the live paired-Mac control stream, Mac `MercuryRouter` surfaces a `.callRinging` approval prompt, and accept/decline replies with `media.call.ack`; Swift protocol tests, Android relay/app tests, Android `:app:assembleDebug`, and the Mac app build pass. Remaining live UI proof is blocked by Samsung lock-screen bouncer covering the app window, and live mirror transport still depends on enabling Local Network for the current Mac app.
- **2026-05-18 iOS Mercury presence ingest:** iOS `MediaControlStreamCoordinator` now forwards inbound Mac `media.presence.heartbeat` frames through `HermesIrohRelayTransport.mediaPresenceHeartbeatHandler`, and Hermes Square installs that handler into `MercuryPeerSource.ingestHeartbeat(_:)`. This removes the stale "heartbeat ingest is future work" path so the iPhone paired-Mac tile and Mercury Live sheet can consume the Mac's current display name/capabilities from the persistent `media.control` stream. Verification: `xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobile -destination 'generic/platform=iOS' -derivedDataPath /tmp/DerivedData-codex-mobile-presence -quiet build` passed. The focused `OpenBurnBarMobileTests/MediaControlStreamPresenceTests` test was added but could not complete on this Mac's available "Designed for iPad/iPhone" destination; XCTest launched the app and then hung until interrupted, so the runnable proof is currently compile-only.
- **2026-05-18 tray + Android mirror hotfix:** The Mac tray item now uses a direct AppKit `NSStatusItem` action for left-click dashboard opening instead of relying on an attached menu, with the menu retained only as a manual right-click fallback. Android media-control dialing now verifies the Firestore `iroh_pairing/{connectionId}` record and dials the Mac's published `IrohDialTarget` (`nodeId`, `relayURL`, direct addresses) instead of accidentally starting an Android endpoint and connecting to itself. Verification: `./gradlew :app:compileDebugKotlin --no-daemon` passed, `./gradlew :app:assembleDebug --no-daemon` passed, `xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS' -derivedDataPath /tmp/DerivedData-codex-tray-mirror -quiet build` passed, current APK installed on Samsung `R3CXB0CNS0J`, current Mac build installed to `~/Applications/OpenBurnBar.app`, `open -b com.openburnbar.app openburnbar://dashboard` produced a visible dashboard-window trace, and `/v1/models` still reports 50 models with 0 duplicate IDs. Follow-up current-checkout proof rebuilt with `make build`, installed `~/Applications/OpenBurnBar.app` timestamped `May 18 06:57:23 2026`, clicked the real `OpenBurnBar` menu-bar item through System Events, and verified an onscreen CoreGraphics window named `OpenBurnBar` at `1360x820`; `openburnbar://dashboard` resolved to the same onscreen window, and `/v1/models` remained 50 models with 0 duplicate IDs. Remaining live Android visual proof is still blocked by the Samsung keyguard bouncer covering `com.openburnbar/.MainActivity`.
- **Acceptance gate remaining:**
  - [x] `AgentWatchView` SwiftUI surface · landed
  - [x] `PhoneControlOptionSheet` Take-over UI · landed for tap, type, Return, Escape, and Command-L controls
  - [x] Drag phone-control gestures · landed for drag-to-scroll
  - [x] Replace in-band phone-control public-key registration with a key rooted in verified pairing + trusted-device state
  - [x] Receiver-level 1,000 replay chaos proof
  - [x] Live Android -> Mac paired-device signed input proof for tap/scroll/panic routing
  - [x] Resolve Mac Accessibility/TCC mismatch so live paired-device tap/scroll execute instead of audited `accessibility_revoked` denial
  - [x] Android row of live paired-device 100-intent latency proof: 100/100 executed, p95 162.0 ms Mac receive-to-dispatch
  - [x] Android row of live paired-device 1,000 replay/tamper chaos proof: 0 bad frames executed
  - [x] Android row of live paired-device approval proof: Android received `control.approval.request`, sent matching `control.approval.response`, Mac executed the pending action, and audit entry `0` read back `approvedBy: phone`
  - [ ] Full device-matrix live paired-device replay/tamper chaos proof
  - [ ] Live paired-device 100 intents/device with p95 latency ≤ 200 ms
  - [ ] 7-day soak

## Phase 13 — Polish

- **Flag:** `computer_use_polish_enabled` · default off
- **Code landed (2026-05-17):**
  - `ComputerUseScopeLibrary` with 3 starter bundles (`GitHub PR triage`, `Gmail archive`, `Calculator`) + `freshlyStampedRules()` for 24h/50-action expiry
  - `ComputerUseAuditExportWriter` signed `.tar.gz` archive format (POSIX ustar + gzip + detached Ed25519 signature sidecar; tamper detection passes)
  - `ComputerUseKeychainAuditExportSignerProvider` stores the export signing key in the local Keychain, migrates/removes the prior raw daemon key file, and writes trusted-device metadata + public-key SHA-256 into the sidecar
  - Audit-export signer public-key readback writes to `users/{uid}/escrow_devices/{deviceId}/computer_use_audit_export_signers/{publicKeySHA256Hex}` after Settings export; Firestore rules bind it to trusted macOS escrow devices, disable deletes, and allow explicit signer revocation.
  - `ComputerUseAuditExportWriter.verify(..., signatureTrust: .trustedDeviceReadback(record))` rejects revoked or mismatched readback records.
  - `ComputerUseOpenTimestampsClient` + `ComputerUseOpenTimestampsArchive` (POSTs SHA-256 digest to calendar server, persists `.ots` proof + JSON sidecar)
  - `validateOpenTimestampsProof` Cloud Function (auth/App Check guarded, server head cross-check, injectable verifier/head dependencies for deterministic tests, delegates Bitcoin proof verification to `OPENBURNBAR_OTS_VERIFY_URL` or local `ots verify`)
  - Dockerized verifier service in `tools/opentimestamps-verifier-service/` packages the official `opentimestamps-client==0.7.2` CLI for Cloud Run.
  - Settings → Computer Use → Audit operations now gates OpenTimestamps notarization behind an Advanced disclosure + explicit per-session opt-in checkbox before submitting the audit-chain digest.
- **Test coverage:** 2 ScopeLibrary tests · 7 AuditExportWriter tests · 3 AuditExportSignerProvider daemon tests · 4 OpenTimestampsClient tests · 16 Firestore emulator cases including audit-export signer trusted-device readback/revocation · Functions `test:computer-use-opentimestamps` including HTTP verifier delegation · local verifier-service smoke (`/health` OK; invalid proof returns 422 from official `ots`)
- **Production proof (2026-05-18):** Cloud Run service `openburnbar-ots-verifier` deployed in `burnbar/us-central1` as revision `openburnbar-ots-verifier-00002-kdf`, private auth kept on. `validateOpenTimestampsProof(us-central1)` is active with `OPENBURNBAR_OTS_VERIFY_URL=https://openburnbar-ots-verifier-cjrjb5ckqq-uc.a.run.app/verify` and matching audience. Smoke used the Function service account identity token: `GET /health` returned `{"ok":true,"service":"opentimestamps-verifier"}` and invalid proof verification returned HTTP 422 from the official `ots` CLI.
- **Acceptance gate remaining:**
  - [ ] Phase 12 soak window cleared
  - [x] User-opt-in flow in Settings → Computer Use → Advanced
  - [ ] Prove 10/10 upgraded Bitcoin-header validations through the deployed production verifier.
