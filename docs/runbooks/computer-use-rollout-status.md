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
- **Test coverage (`swift test --filter OpenBurnBarComputerUseCoreTests`):** 80 tests green covering Phase 8 substrate (5 codec-cursor tests in `MediaPacketCodecTests`)
- **Acceptance gate remaining:**
	  - [ ] Mercury Phase 3 ≥ 95% success for the prior 7 days
	  - [ ] 5 consecutive Mac→iPhone "agent triages 3 emails via Mail" runs across LAN + LTE
	  - [ ] TestFlight 5% rollout

## Phase 9 — Browser Computer Use (Manual mode)

- **Flag:** `computer_use_browser_enabled` · default off
- **Code landed (2026-05-17):**
  - 13 new `BurnBarToolKind` cases + 7 new `BurnBarBrowserActionKind` cases
  - `OpenBurnBarPlaywrightDriver` + `OpenBurnBarPlaywrightLifecycle` (auto-install pinned `playwright@1.49.1`)
  - Node.js bridge script `openburnbar-playwright-bridge.js`
	  - `ComputerUseRunCoordinator` daemon-side orchestrator
	  - `BurnBarComputerUseContracts.swift` socket-RPC contracts
	  - `BurnBarAgentLoopActionKind` now accepts browser actions; daemon browser RPC dispatches Playwright `click/fill/goto/key/select/screenshot/extract` instead of rejecting them
	  - `ComputerUseApprovalSheet` SwiftUI surface
	  - `scripts/install-playwright.sh` + `scripts/test-computer-use-loopback.sh` + `.github/workflows/computer-use-loopback-test.yml`
- **Test coverage:** Daemon `swift build` green; `BurnBarBrowserToolServiceComputerUseTests` proves Playwright interactive dispatch and non-Playwright fail-closed behavior.
- **Acceptance gate remaining:**
	  - [ ] `hosted_computer_use_sync` + `burnbar_pro_max` SKUs accepted by App Store review
	  - [ ] `NSAppleEventsUsageDescription` re-submission accepted
	  - [ ] 100 TestFlight users at ≥ 95% scripted-scenario completion

## Phase 10 — Trust modes + scope rules + audit chain

- **Flag:** `computer_use_trust_modes_enabled` · default off
- **Code landed (2026-05-17):**
  - `ComputerUseTrustMode` + `ComputerUseScopeRule` + `ComputerUseScopeMatcher`
  - `ComputerUseDenyRegistry` with 12 built-in deny entries
  - `ComputerUseAuditChain` + `ComputerUseAuditLogger` + `ComputerUseAuditHasher` (SHA-256, BLAKE3-swappable)
  - `ComputerUseSessionPanel` Mac UI surface
  - `ComputerUseApprovalSheet` step-mode burst approval toggle
- **Test coverage:** 14 ScopeMatcher tests · 6 AuditChain tests · 14 CapabilityGate tests · 3 AuditExport tests
- **Acceptance gate remaining:**
  - [ ] 7-day internal-user soak with zero unintended Trusted-mode escapes

## Phase 11 — Mac System Computer Use

- **Flag:** `computer_use_system_enabled` · default off
- **Code landed (2026-05-17):**
  - `MacInputController` (CGEvent wrapper, display-bounds gated, delegates to `MacInputCore`)
  - `MacAccessibilityInspector` (AX role/subrole + deny-region matcher)
  - `ComputerUsePanicHaltCoordinator` (hotkey + auth-gate + remote-config kill paths)
  - `ComputerUseSetupWizard` Accessibility-permission flow
  - `#if !DISTRIBUTION_MAS` compile-out applied to MacInputController, MacAccessibilityInspector, ComputerUseSetupWizard, PhoneControlReceiver
- **Test coverage:** 9 MacInputCore tests (virtual-key map, modifier flags, display-bounds containment)
- **Acceptance gate remaining:**
  - [ ] ≥ 14-day Phase 9 soak with ≥ 95% success rate
  - [ ] Direct-download notarized build verified via `spctl --assess`

## Phase 12 — Phone-as-controller

- **Flag:** `computer_use_phone_control_enabled` · default off
- **Code landed (2026-05-17):**
  - `ComputerUsePhoneControlSigner` (Ed25519 + canonical-JSON intent hashing; `control.input` hashes exclude the attached authority envelope)
  - iOS `PhoneControlAuthorityIssuer` + `PhoneControlSender` (signed envelope → `control.input` frame → iroh write)
  - Mac `PhoneControlAuthorityValidator` + `PhoneControlReceiver` (decode → validate → translate normalized intent → dispatch via run coordinator; emits `control.denied` on validation failure)
  - Trust-mode downgrade-from-phone wired through `AgentWatchState.setTrustMode` (Mac coordinator subscribes)
- **Test coverage:** 15 PhoneControlSigner golden-case tests proving signature, replay, freshness, intent-hash, peer-key, payload-stability, attached-authority, and tamper semantics · 5 MacInputCore normalized-coordinate tests
- **Acceptance gate remaining:**
  - [ ] `AgentWatchView` SwiftUI surface · landed
  - [ ] `PhoneControlOptionSheet` Take-over UI · pending
  - [ ] 7-day soak

## Phase 13 — Polish

- **Flag:** `computer_use_polish_enabled` · default off
- **Code landed (2026-05-17):**
  - `ComputerUseScopeLibrary` with 3 starter bundles (`GitHub PR triage`, `Gmail archive`, `Calculator`) + `freshlyStampedRules()` for 24h/50-action expiry
  - `ComputerUseAuditExportWriter` signed `.tar.gz` archive format (POSIX ustar + gzip + detached Ed25519 signature sidecar; tamper detection passes)
  - `ComputerUseOpenTimestampsClient` + `ComputerUseOpenTimestampsArchive` (POSTs SHA-256 digest to calendar server, persists `.ots` proof + JSON sidecar)
  - `validateOpenTimestampsProof` Cloud Function (auth/App Check guarded, server head cross-check, delegates Bitcoin proof verification to `ots verify` when available)
- **Test coverage:** 2 ScopeLibrary tests · 6 AuditExportWriter tests · 4 OpenTimestampsClient tests · Functions `test:computer-use-opentimestamps`
- **Acceptance gate remaining:**
  - [ ] Phase 12 soak window cleared
  - [ ] User-opt-in flow in Settings → Computer Use → Advanced
  - [ ] Replace device-local Ed25519 signer with the plan's Apple/iCloud device-certificate signing identity, or amend the plan.
  - [ ] Package/provision the official `ots` verifier in production Cloud Functions, then prove 10/10 Bitcoin-header validations.
