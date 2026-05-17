# Computer Use master-plan implementation audit

**Audit date:** 2026-05-17T18:19:12Z  
**Plan audited:** `plans/2026-05-16-computer-use-master-plan.md`  
**Original Claude session:** `~/.claude/projects/-Users-albertonunez-Documents-Windsurf-BurnBar/fc132f73-a087-4fcd-8e79-e08f686bd562.jsonl`  
**Resume:** `claude --resume fc132f73-a087-4fcd-8e79-e08f686bd562`

## Executive verdict

**Not launch complete.** The implementation now has a real tested substrate, current-checkout Mac/iOS builds pass, Android reducer tests pass, the browser bridge smoke passes after reinstalling the pinned Playwright browser, and the core safety primitives exist. It does **not** satisfy the master plan's launch gates yet because several required device, soak, App Store, notarization, and audit-export requirements are still missing or only partially implemented.

## Current verified evidence

Commands run from the current checkout, not from the old `build/DerivedData-claude-quota-live` app:

| Check | Result |
|---|---|
| `swift test --package-path OpenBurnBarCore --filter OpenBurnBarComputerUseCoreTests` | 80 tests, 0 failures |
| `swift test --package-path OpenBurnBarCore --filter ComputerUsePhoneControlSignerTests` | 15 tests, 0 failures |
| `swift test --package-path OpenBurnBarCore --filter 'MacInputCoreTests|ComputerUsePhoneControlSignerTests'` | 26 tests, 0 failures |
| `swift test --package-path OpenBurnBarCore --filter ComputerUseAuditExportWriterTests` | 6 tests, 0 failures |
| `swift test --package-path OpenBurnBarDaemon --filter ComputerUseRunCoordinatorTests` | 8 tests, 0 failures |
| `cd functions && npx tsc --noEmit` | exit 0 |
| `cd functions && npm run build && node scripts/test-computer-use-opentimestamps.mjs` | exit 0 |
| `cd android && ./gradlew :app:testDebugUnitTest --tests '*ComputerUse*' --no-daemon` | build successful |
| `scripts/install-playwright.sh` | exit 0; installed pinned Playwright 1.49.1 Chromium/headless shell |
| `bash scripts/test-computer-use-loopback.sh` | exit 0; `goto`, `current_url`, `shutdown` all OK |
| `xcodebuild -scheme OpenBurnBar ... -derivedDataPath build/DerivedData-cu-audit-current build` | exit 0 |
| `xcodebuild -scheme OpenBurnBar ... -derivedDataPath build/DerivedData-cu-targz-current build` | exit 0 |
| `xcodebuild -scheme OpenBurnBar ... -derivedDataPath build/DerivedData-cu-current-normalized build` | exit 0 |
| `xcodebuild -scheme OpenBurnBarMobile -destination id=AFB07C15-AD18-5EFA-AD1C-CADB4F286797 ... build` | exit 0 |
| `xcodebuild -scheme OpenBurnBarMobile ... -derivedDataPath build/DerivedData-cu-phone-hash-ios-fix build` | exit 0 after adding the missing `.deepSeek` provider setup guide |

No app was launched during this audit.

## Phase-by-phase status

| Phase | Plan requirement | Current status | Evidence | Gap |
|---|---|---|---|---|
| 8 Agent Watch | Real Mac agent run mirrors to paired phone with live surface, action overlay, and visual approval row | Partial | `AgentWatchHUDSession`, `AgentWatchActionPublisher`, iOS `AgentWatchReceiver`, `AgentWatchView`, Android reducer/screen exist. iOS view has `AVSampleBufferDisplayLayer` decode path. | No filled Phase 8 device matrix. No 5 consecutive Mac to iPhone LAN/LTE Mail runs. No `iroh_audit_events` export proof. No Android live stream proof. |
| 9 Browser CU | Playwright Chromium driven through approval-gated tools, SKU live, scenario/device gates | Partial | Driver/lifecycle/bridge exist. Loopback smoke passes after `scripts/install-playwright.sh`. Daemon coordinator tests pass. | Only 3-command bridge smoke was run here, not the plan's 5 deterministic scenarios x 5 runs, 50 runs per device, 100 TestFlight users, App Store SKU live/accepted, or App Store resubmission acceptance. |
| 10 Trust, scopes, audit | Manual/Step/Trusted, scope matcher, deny registry, audit chain, Step burst 10 actions or 30s | Mostly code-complete, not rollout-complete | Core tests pass. Step burst is implemented in `ComputerUseRunCoordinator` and covered by two daemon tests. | Plan asks for full Phase 9 scenarios rerun in Step/Trusted, 100/100 chain validations, tamper-at-every-entry fixtures, and 7-day soak. Those are not proven. |
| 11 Mac System CU | CGEvent + AX, setup flow, MAS compile-out, direct-download notarized build, device scenarios | Partial | `MacInputController`, `MacAccessibilityInspector`, deny-region classifier, `MacActionDispatcher`, setup wizard, and MAS guards exist. Mac build passes. Prior local CGEvent smoke reportedly posted a click. | Daemon RPC system mode fails closed with `accessibilityTrusted: false`; app-owned coordinator uses live AX. No Calculator 50/50, TextEdit 50/50, deny-region 12/12 device proof, MAS `DISTRIBUTION_MAS` build proof, notarized Developer ID build, or `spctl --assess`. |
| 12 Phone controller | Signed phone intents, real `control.input`, approval from phone, p95 latency, replay/tamper chaos | Partial | iOS sender/issuer, Mac receiver/validator, iOS control stream coordinator, approval response path, and 15 phone signer tests exist. Real `control.input` signing now hashes the action fields without the attached authority envelope, and tests prove attached-authority round trip plus tamper rejection. Normalized phone coordinate translation now lives in `MacInputCore` and has 5 direct tests. iOS physical build passes. | `AgentWatchReceiver.panicHalt` builds an empty-authority intent before `PhoneControlSender` re-signs it; OK if sender is always present, but nil sender silently only clears local state. No real phone to Mac signed input loop, 100 intents/device, p95 latency, 1000 replay chaos, or 7-day error-rate proof. |
| 13 Polish | Trusted scope library, expiry, signed `tar.gz` audit export with iCloud device certificate, OpenTimestamps verification | Partial | Scope library and OTS client/archive exist. Export now writes a real `.tar.gz` plus detached Ed25519 signature; tests verify parsing, tamper detection, signature validation, and `/usr/bin/tar -tzf` readability. `validateOpenTimestampsProof` now exists server-side and cross-checks the submitted head against Firestore before delegating to `ots verify` when available. | Signature is device-local Ed25519, not an Apple iCloud device certificate. Production Cloud Functions still need an installed/provisioned OpenTimestamps verifier before Bitcoin-header proof can pass. No OTS proof verification 10/10. |

## Important implementation mismatches

### P0 reduced to P1: audit export format is now tar.gz, but signer identity still is not the planned iCloud certificate

The master plan says Phase 13 export must produce a signed `tar.gz` containing the JSONL chain and screenshots, signed with the user's iCloud device certificate. This audit found the previous writer emitted `.cua`; that has been corrected to a real gzip-compressed POSIX tar with a detached Ed25519 signature sidecar. The remaining mismatch is signer identity: the implementation signs with a local OpenBurnBar device Ed25519 key, not an Apple/iCloud device certificate.

Evidence:
- `plans/2026-05-16-computer-use-master-plan.md:1127`
- `OpenBurnBarCore/Sources/OpenBurnBarCore/Contracts/BurnBarComputerUseContracts.swift:190`
- `OpenBurnBarCore/Sources/OpenBurnBarComputerUseCore/ComputerUseAuditExportWriter.swift`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/ComputerUseService.swift:154`

Resolution needed: either provide a real Apple/iCloud-backed signing identity to the export writer, or formally amend the plan from "iCloud device certificate" to "OpenBurnBar device-local Ed25519 signing key." Do not call this plan-complete while the signer identity still differs from the plan.

### P1: daemon System-mode route is not real Mac input yet

`ComputerUseService.invoke` builds capability with `accessibilityTrusted: false`, so daemon-routed System-mode input fails closed. The app-owned `ComputerUseSessionCoordinator` uses `inputController.isAccessibilityTrusted()` and can dispatch real CGEvents, but the daemon RPC path is not a real System-mode executor.

Evidence:
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/ComputerUseService.swift:97`
- `OpenBurnBarDaemon/Sources/OpenBurnBarDaemon/ComputerUse/ComputerUseService.swift:104`
- `AgentLens/Services/ComputerUse/ComputerUseSessionCoordinator.swift:354`
- `AgentLens/Services/ComputerUse/ComputerUseSessionCoordinator.swift:361`

Resolution needed: clarify architecture. If daemon is Browser-only and app owns Path C, docs/contracts should say that. If daemon RPC is intended to execute Path C, it needs a real app bridge for AX trust, scope context, deny regions, and Mac dispatch.

### P1: OpenTimestamps server hook exists, but production verifier packaging remains open

`validateOpenTimestampsProof` is now exported from Cloud Functions. It enforces Firebase Auth/App Check ownership, checks the submitted audit head against `users/{uid}/computer_use_sessions/{sessionId}.auditHeadHashHex`, validates the proof payload shape/size, and runs `ots verify` if the runtime has the official verifier available. It returns `ots_verifier_unavailable` rather than claiming success when the binary is absent.

Evidence:
- `functions/src/computerUseOpenTimestamps.ts`
- `functions/src/index.ts`
- `functions/scripts/test-computer-use-opentimestamps.mjs`

Resolution needed: package/provision the official OpenTimestamps verifier in the production Cloud Functions runtime, then record 10/10 verified notarized sessions.

### P1: rollout docs are checklists, not proof

`docs/runbooks/computer-use-device-matrix/phase-9.md`, `phase-11.md`, and `phase-12.md` are manual checklists. They do not record completed device runs, pass/fail rows, dates, or evidence links. There is no Phase 8 device-matrix result file in this audit.

Resolution needed: convert device matrix files into result logs before flag flip. Record exact device, OS, network, build, run count, latency p95, failures, and evidence path.

### P1: App Store and distribution gates remain external

The plan requires live/accepted SKUs, App Store resubmission acceptance, direct-download notarization, and `spctl --assess`. The codebase has StoreKit/ASC tooling and status docs, but this audit did not find production-live SKU approval, accepted resubmission, or notarized direct-download proof.

Resolution needed: complete App Store Connect review and direct-download notarization outside code, then attach evidence.

## Current compile-error status

There is no current Computer Use Swift compile error in this audit. The known `ComputerUseSettingsView.swift` issue was `client.calendarURL`; it was fixed to `client.configuration.calendarURL` before the current Mac build. A later iOS physical-device rebuild failed on a non-Computer-Use exhaustive switch in `OpenBurnBarMobile/Views/Onboarding/ProviderSetupGuide.swift` after `.deepSeek` was added to `AgentProvider`; this audit fixed that by adding a real DeepSeek setup guide, and the physical-device build now exits 0. Current warnings are unrelated pre-existing Swift 6 Sendable/deprecation warnings in Cast and mobile media code.

## What is genuinely done

- Shared Computer Use core exists and is tested.
- Browser bridge can currently drive Playwright Chromium in loopback.
- Mac and iOS app targets compile from the current checkout.
- Android has a tested Agent Watch reducer/surface scaffold.
- Step-mode burst approval exists and is tested at daemon coordinator level.
- Approval presenter, approval sheet, scope rules, audit chain, OTS mock path, phone signing, and panic primitives exist.

## What is not done

- Full plan acceptance gates.
- Real Phase 8 Mac to iPhone/iPad/Android LAN/LTE evidence.
- Phase 9 deterministic scenario suite and TestFlight/user gates.
- Phase 10 soak and full trusted-scope escape proof.
- Phase 11 direct-download notarized distribution and 50/50 app scenarios.
- Phase 12 real phone-to-Mac input latency, replay, tamper, and cross-device approval proof.
- Phase 13 iCloud device-certificate signature identity.
- OpenTimestamps proof verification against Bitcoin block headers for 10/10 sessions.

## Recommendation

**Continue hardening. Do not mark the master plan complete.**

Next highest-value engineering fix is the remaining Phase 13 signer-identity mismatch: either wire the export signer to a real Apple/iCloud-backed certificate identity or amend the plan to the device-local Ed25519 identity now implemented. Next highest-value validation work is a real Phase 8/12 paired-device run because it tests the hardest product promise: "watch from phone, intervene from phone, stop the Mac."
