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
	  - `OpenBurnBarComputerUseCore` wired into `OpenBurnBar.xcodeproj` for both AgentLens (macOS) + OpenBurnBarMobile (iOS) targets · `xcodebuild build` green
	  - `IrohRelayRequestHandler` dispatches control frames via `ControlFrameDispatcher`
- **Implementation status:** Mac now has `AgentWatchHUDSession` + `AgentWatchActionPublisher`; iOS `AgentWatchView` now owns an `AVSampleBufferDisplayLayer` decode path for `MediaFrame` surface frames. Full iroh surface-frame fanout still needs real-device LAN/LTE proof before flag flip.
- **Test coverage (`swift test --filter OpenBurnBarComputerUseCoreTests`):** 84 tests green covering Phase 8 substrate (5 codec-cursor tests in `MediaPacketCodecTests`)
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
- **Test coverage:** Daemon `swift build` green; `OpenBurnBarPlaywrightDriverTests` proves mock-subprocess JSON-RPC method/parameter mapping for click/fill/goto/key/select/screenshot/extract and covers the subprocess-exit drain path; `BurnBarBrowserToolServiceComputerUseTests` proves Playwright interactive dispatch and non-Playwright fail-closed behavior; `ComputerUseRunCoordinatorTests` covers browser approval approve/reject/scope-denied paths, Trusted-mode allow-rule dispatch without an approval sheet, and Step-mode 10-action browser burst execution from one approval; those tests decode the resulting audit-chain entries to prove `approvedBy`, `approvalId`, `denyReason`, `scopeRuleId`, action kind, and chain length, and assert Manual/Step browser approval requests include pre-action PNG evidence fields. `ComputerUseRunCoordinatorPlaywrightScenarioTests` is opt-in and, with `RUN_COMPUTER_USE_PLAYWRIGHT_SCENARIOS=1`, drives real Playwright Chromium through the coordinator in Step and Trusted modes across all seven browser tool kinds; Step records 7 explicit approvals + 7 audit entries, Trusted records 0 approvals + 7 `trusted_scope` audit entries. Real Playwright Chromium proof: `node scripts/test-computer-use-browser-scenarios.mjs --runs 5` passed 25/25 deterministic local-browser scenarios across 96 bridge RPCs, exercising goto/current title/current URL/extract/fill/click/select/key/coordinate click/screenshot with RPC p95 41 ms. Phase 9 plan-shape proof: `node scripts/test-computer-use-browser-scenarios.mjs --runs 5 --scenario-set phase9-plan` passed 25/25 scenarios across 91 bridge RPCs, covering Wikipedia search, GitHub repo navigation, form fill, multi-page flow, and error recovery with RPC p95 500 ms.
- **Acceptance gate remaining:**
	  - [ ] `hosted_computer_use_sync` + `burnbar_pro_max` SKUs accepted by App Store review
	  - [ ] `NSAppleEventsUsageDescription` re-submission accepted
	  - [ ] 50 scenario runs per device with audit-chain validation on every run
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
- **Test coverage:** 9 MacInputCore tests (virtual-key map, modifier flags, display-bounds containment) · `ComputerUseRunCoordinatorTests` proves daemon `ComputerUseService` rejects app-owned Path A/C modes at session start · Calculator loopback proof: `tools/CUClickSmoke --scenario calculator --runs 50` passed 50/50 via CGEvent typing + AX result readback (`p95=157.25 ms`) · MAS compile-out proof: `xcodebuild ... OTHER_SWIFT_FLAGS='$(inherited) -D DISTRIBUTION_MAS' build` exit 0
- **Acceptance gate remaining:**
  - [ ] ≥ 14-day Phase 9 soak with ≥ 95% success rate
  - [x] Calculator 50/50 loopback
  - [ ] TextEdit 50/50 loopback
  - [ ] Deny-region 12/12 proof
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
  - Android `PhoneControlAuthorityPublisher` writes the phone control public key to `iroh_pairing/{connectionId}/controllers/{peerNodeId}` with the same schema/rules shape as iOS, and `PhoneControlSigningKeyStore` persists the Ed25519 seed wrapped by Android Keystore AES-GCM.
  - Phone scroll maps to first-class `mac_input_scroll` / `MacInputAction.Kind.scroll` and posts a real CGEvent scroll instead of degrading to click
  - Trust-mode downgrade-from-phone wired through `AgentWatchState.setTrustMode` (Mac coordinator subscribes)
- **Test coverage:** 16 Swift PhoneControlSigner golden-case tests proving signature, replay, freshness, intent-hash, peer-key, payload-stability, attached-authority, drag endpoint hash coverage, and tamper semantics · 19 Android Computer Use JVM tests covering watch reducer, Tink signing, canonical JSON, big-endian payload, replay/freshness/tamper/foreign-key rejection, drag endpoint hash coverage, Swift Date compatibility, signed `control.input.intent` frame emission, per-peer counter increment, missing-key failure, and authority-doc Firestore map shape/peer-id validation · Android relay codec test round-trips a `control.input.intent` frame through the real length-prefixed JSON codec · 5 MacInputCore normalized-coordinate tests · `PhoneControlReceiverTests` prove signed scroll dispatch + malformed-coordinate denial, coordinator-level `control.classify` authority fetch followed by signed phone `.panic`, and stream-level `IrohRelayRequestHandler.serve()` routing of `control.classify` + signed `control.input.intent` into the active coordinator · iOS build-for-testing covers `AgentWatchReceiver` signed tap/scroll sender path · physical iPhone 17 Pro Max run passed `OpenBurnBarMobileTests/OpenBurnBarMobileTests/testAgentWatchReceiverSendsSignedTapAndScrollIntents` (1/1) · current-checkout `OpenBurnBarMobile.app` built, installed, and launched on the physical iPhone 17 Pro Max · Firestore emulator covers trusted-device + active-pairing gating for phone authorities
- **Acceptance gate remaining:**
  - [x] `AgentWatchView` SwiftUI surface · landed
  - [x] `PhoneControlOptionSheet` Take-over UI · landed for tap, type, Return, Escape, and Command-L controls
  - [x] Drag phone-control gestures · landed for drag-to-scroll
  - [x] Replace in-band phone-control public-key registration with a key rooted in verified pairing + trusted-device state
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
- **Test coverage:** 2 ScopeLibrary tests · 7 AuditExportWriter tests · 3 AuditExportSignerProvider daemon tests · 4 OpenTimestampsClient tests · 16 Firestore emulator cases including audit-export signer trusted-device readback/revocation · Functions `test:computer-use-opentimestamps` including HTTP verifier delegation · local verifier-service smoke (`/healthz` OK; invalid proof returns 422 from official `ots`)
- **Acceptance gate remaining:**
  - [ ] Phase 12 soak window cleared
  - [x] User-opt-in flow in Settings → Computer Use → Advanced
  - [ ] Deploy the verifier service, set `OPENBURNBAR_OTS_VERIFY_URL` in production Functions, then prove 10/10 upgraded Bitcoin-header validations.
