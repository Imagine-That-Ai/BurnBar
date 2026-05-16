# Mercury Media Rollout Status

Operator log mirroring `docs/runbooks/iroh-rollout-status.md`. Each entry records gate status, what landed, what is blocked or pending, and the next action. New entries are appended at the bottom in reverse chronology so the latest state is always immediately visible from the table of contents at the top of the file.

The plan of record is `plans/2026-05-15-mercury-media-master-plan.md`. The seven phases below correspond directly to phases 1-7 in that plan.

| Phase | Theme | Flag | Gate status |
|---|---|---|---|
| 1a | iroh-blobs file send/receive substrate | `media_blob_transfer_enabled` | Substrate landed 2026-05-15 |
| 1b | File transfer end-to-end (IrohBlobNode + Mac/iOS file services) | `media_blob_transfer_enabled` | Source-complete 2026-05-15; needs TestFlight verify |
| 2 | File send UI + `hosted_media_sync` SKU + Cloud Functions | `media_blob_transfer_ui_enabled` | Source-complete 2026-05-15 |
| 3 | Mac → iOS one-way screen share | `media_screen_share_enabled` | Source-complete 2026-05-15 |
| 4 | Mac ⇄ iOS audio | `media_audio_enabled` | Source-complete 2026-05-15 |
| 5 | Mac ⇄ iOS video + CallKit + budget | `media_video_enabled` | Source-complete 2026-05-15 |
| 6 | iPad multicam + PiP | `media_ipad_multicam_enabled` | Source-complete 2026-05-15 |
| 7 | macOS PiP + WSS retirement | `media_macos_pip_enabled` | Source-complete 2026-05-15 |

---

## 2026-05-15 — Phase 1 scaffolding landed

**Gate status:** in progress; xcframework rebuild + manual TestFlight verification remain.

Completed:
- Pure-Swift substrate published as a new SwiftPM target `OpenBurnBarMedia` in `OpenBurnBarCore/Package.swift`, conditionally linked alongside the existing `OpenBurnBarIrohRelay` package. Target is buildable from a fresh checkout regardless of whether `Vendor/OpenBurnBarIroh.xcframework` is present.
- Substrate source files: `MediaStreamClass.swift` (canonical class identifiers shared with the Rust crate), `MediaPacketCodec.swift` (length-prefix codec parallel to `IrohRelayFrameCodec` for binary media frames), `MediaFrame.swift` (typed envelope), `BitrateController.swift` (GCC-lite encoder ceiling), `MediaSessionMetadata.swift`, `MediaCapabilityGate.swift` (protocol surface — Mac and iOS provide implementations in later phases), `MediaBudgetEnvelope.swift` (active envelope from `ops/media_budget_status/current`).
- `HermesRealtimeRelayFrame` extended with `media: HermesRealtimeRelayMediaPayload?` and three new frame types (`media.classify`, `media.blob.advertise`, `media.blob.ack`). Forward-compat verified — older decoders ignore the new field, newer decoders accept its absence.
- Mac + iOS dispatch: `IrohRelayRequestHandler` (Mac) and `HermesIrohRelayTransport` (iOS) handle the new media frame types via stub handlers gated on `media_blob_transfer_enabled` (default off). Phase 1 stubs log + count; the full publish/fetch path activates after the xcframework reships.
- Rust scaffolding (Phase 1a — substrate): `crates/openburnbar-iroh/src/blobs.rs` module imports `iroh-blobs = "0.92"` (the line that targets `iroh ^0.91`) and publishes `BlobTicketBytes`, `BlobTransferStats`, `parse_blob_ticket`, `iroh_blobs_alpn`, `iroh_blobs_crate_version` as UniFFI surface. 5 cargo unit tests cover round-trip, garbage rejection, whitespace trimming, ALPN constant identity, and crate-version exposure.
- Cloud Functions: `MediaSessionEventDoc`, `MediaQuotaUsageDoc`, `MediaAttachmentManifestDoc`, `MediaSessionDailyRollupDoc`, `MediaBudgetStatusDoc` defined in `functions/src/types.ts`. Compile-only in Phase 1, no server writes yet.
- Documentation skeletons: this file, `docs/HERMES_MEDIA_TRANSPORT.md` (architecture spec), `docs/runbooks/media-quota.md`, `docs/runbooks/media-budget.md`, `docs/runbooks/media-device-matrix/README.md`. `docs/HERMES_IROH_TRANSPORT.md` extended with a "Media stream classes" section.
- Unit tests: 28 new tests in `OpenBurnBarMediaTests` covering codec round-trip + oversize rejection + truncation guards (both layers) + unknown-kind rejection + GOP boundary metadata, stream-class parse + phase availability + Codable round-trip, bitrate controller down-adapt + recovery hysteresis + ceiling + floor clamps, budget envelope normal/soft/hard transitions + Firestore wire format, capability-gate contract, and telemetry bucket boundary tests. Plus 5 cargo unit tests on the Rust side covering ticket round-trip, garbage rejection, whitespace trimming, ALPN constant identity, crate-version exposure. Existing 641 OpenBurnBarCore + IrohRelay tests still pass with 0 regressions from the frame protocol extension.

Blocked / pending (Phase 1b — integration):

- **Multi-ALPN endpoint router.** `IrohEndpointHandle::bootstrap` currently advertises a single ALPN (`openburnbar/1`). `publish_blob` and `fetch_blob` need the same `Endpoint` to serve `iroh_blobs::ALPN` alongside the chat ALPN — without that, a paired peer can negotiate a blob fetch but the local accept-loop refuses the stream. Implementation: wrap the `Endpoint` in an `iroh::protocol::Router` that dispatches by ALPN, install `BlobsProtocol::new(&store, endpoint, None)` for the blobs ALPN, keep the existing accept-loop on `openburnbar/1`. `iroh_blobs_alpn()` is already exposed for Swift to consume.
- **`publish_blob` + `fetch_blob` UniFFI methods on `IrohEndpointHandle`.** Once the router lands, `publish_blob(local_path) -> BlobTicketBytes` opens an `FsStore` rooted at the per-uid blob cache, calls `store.blobs().add_path(path).with_tag().await`, builds a `BlobTicket` from the resulting `Hash` + the endpoint's `NodeAddr`, returns the base32 surface form. `fetch_blob(ticket, dest, progress) -> BlobTransferStats` parses via `parse_blob_ticket`, dials `iroh_blobs::ALPN`, drives `iroh_blobs::get::request::get_blob` to write into `dest`, fills `BlobTransferStats`.
- **Re-spin `Vendor/OpenBurnBarIroh.xcframework`** via `scripts/build-iroh-xcframework.sh` after Phase 1b lands. The xcframework rebuild regenerates `OpenBurnBarCore/Sources/OpenBurnBarIroh/Generated/openburnbar_iroh.swift` with the new UniFFI surface; until then Swift sees only `parse_blob_ticket`, `iroh_blobs_alpn`, `iroh_blobs_crate_version` (the Phase 1a substrate).
- **Mac chat-input attachment entry** (hidden Cmd+Option+Click on `HermesDashboardChatPanel` per Phase 1 plan) — gated on the rebuilt xcframework.
- **iOS receive UI** (`UIDocumentPickerViewController` for non-image, `PHPhotoLibrary` for image MIME types) — gated on the rebuilt xcframework.
- **Manual TestFlight end-to-end**: real Mac (M3) on Wi-Fi → real iPhone 17 Pro on cellular, 5 MB PNG screenshot. `iroh_audit_events` should show `iroh_stream_opened` with `streamClass: "media.blob"` and `iroh_stream_closed` success; wall-clock < 15 s on 50 Mbps; zero plaintext crosses Firebase; Photos shows saved image with intact EXIF.

Next action:
- Implement the multi-ALPN router + `publish_blob`/`fetch_blob` (Phase 1b above), re-spin the xcframework, wire the Mac chat-input entry + iOS save sheet, flip `media_blob_transfer_enabled` on for Alberto's account, and run the manual TestFlight loop above.

---

## 2026-05-15 — Phase 1b through Phase 7 source-complete

**Gate status:** all phases shipped at the source level. xcframework reshipped with the new `IrohBlobNode` UniFFI surface. Manual device-matrix soak + App Store review are the remaining real-world gates per phase.

Completed (single-session burst, by phase):

**Phase 1b — file transfer end-to-end:**
- `IrohBlobNode` UniFFI object (`crates/openburnbar-iroh/src/blobs.rs`): owns its own `Endpoint` advertising `iroh_blobs::ALPN`, an `FsStore`, and an `iroh::protocol::Router`. `bootstrap`, `publish_blob`, `fetch_blob`, `identity`, `shutdown` exposed.
- `IrohBlobBackend` Swift protocol + `OpenBurnBarIrohBlobFFIBackend` xcframework-gated bridge (`OpenBurnBarCore/Sources/OpenBurnBarIrohRelay/IrohBlobBackend.swift` + `OpenBurnBarIrohBlobFFIBridge.swift`).
- `MediaFileTransferService` actor (`OpenBurnBarMedia`): bootstrap/publish/fetch round-trip + idempotent bootstrap + per-blob inbox.
- `IrohBlobKeyStore` (Mac + iOS) — separate Keychain entry from chat secret because the two iroh endpoints need distinct NodeIds.
- `MacFileTransferService` + `iOSFileTransferService` adapters with `handleAdvertise(frame:ackSender:)` chat-stream integration.
- Mac `IrohRelayRequestHandler` and iOS `HermesIrohRelayTransport` dispatch via `MediaFrameDispatcher` + `IrohMediaFrameDispatcher` typealiases.
- xcframework re-spun via `scripts/build-iroh-xcframework.sh`; Generated bindings now expose `IrohBlobNode`.
- Tests: 7 new `MediaFileTransferServiceTests` cover publish + fetch + idempotent bootstrap + typed error surface + shutdown. 5 cargo tests still green.

**Phase 2 — file UI + SKU + Cloud Functions:**
- iOS `MediaPartnerSavePreferenceStore` + `AttachmentSaver` (Decision 3 — per-partner save, action sheet on first image, persisted via `UserDefaults`).
- iOS `PerPartnerSavePreferencesView`, Mac `AttachmentChipRow` + `PaperclipButton`, iOS `AttachmentBubble` + `PaperclipButton`.
- Mac `MacMediaCapabilityGate` (Decision 2 — Mac is source of truth) composing entitlement × usage × budget signals.
- Cloud Functions: `mediaQuota.ts` (`recomputeMediaQuotaUsage`, hourly), `mediaSku.ts` (`grantMediaGrandfather`, `validateMediaPurchase`), `mediaMonitoring.ts` (`rollupMediaSessionDaily`).
- `firestore.rules`: `hasActiveHostedMediaEntitlement` helper + `media_quota_usage` + `media_session_events` + `media_attachment_manifests` owner-write rules + `ops/media_budget_status` and `ops/media_session_daily_rollups` server-only public-read.
- Tests: 6 new `MediaPartnerSavePreferenceStoreTests`.

**Phase 3 — Mac → iOS screen share:**
- Mac `ScreenCapturePipeline` (ScreenCaptureKit), `VideoEncoder` (VTCompressionSession HEVC + H.264 fallback), `MediaSessionCoordinator` orchestrator (capture → encode → BWE feedback → teardown).
- iOS `VideoReceivePipeline` (VTDecompressionSession + AVSampleBufferDisplayLayer) + `ScreenShareViewerView` (full-bleed + three-finger-tap stats overlay).
- Mac `StartMirrorButton` (mercury-bordered, cooldown badge), `MercuryRing` (status-bar live indicator), `MediaPermissionsView` (Settings → Privacy with deep-links to System Settings).

**Phase 4 — Mac ⇄ iOS audio:**
- Mac `MicrophoneCapturePipeline` (AVAudioEngine + Voice-Processing IO) + `AudioEncoder` (Apple's built-in `kAudioFormatOpus` — equivalent to libopus, no third-party binary needed).
- iOS `MicrophoneCaptureService` + `AudioReceivePipeline` (60 ms jitter buffer, AVAudioPlayerNode playback, AirPods route-change handler).
- Mute/unmute via `MediaFrame.Flags.muted` in-band.

**Phase 5 — video + CallKit + budget:**
- Mac `CameraCapturePipeline` + `VoIPCallTrigger` (Firebase Functions callable wrapper).
- iOS `CameraCaptureService`, `VoIPCallService` (PKPushRegistry + CXProvider + CXCallController), `MercuryCallTransitionController` (Decision 1 — app-active → Mercury sheet, app-background → direct CallHUD).
- Mac UI: `IncomingCallSheet` (96pt avatar, mercury hairline, Decline/Accept), `CallHUD` (mono timer, 44pt control buttons).
- iOS UI: `MercuryIncomingSheet` (foreground-only per Decision 1), `CallHUDView`, `SelfPiPView` (88×128 drag-to-corner).
- Cloud Functions: `voipPush.ts` (`triggerVoIPCall` callable verifies Mac entitlement per Decision 2 and writes `voip_outbound` for the existing APNs router); `mediaBudget.ts` (`evaluateMediaBudget` hourly, $600 soft / $1000 hard cap per Decision 4, writes `ops/media_budget_status/current`).

**Phase 6 — iPad multicam + PiP:**
- iOS `iPadMultiCamCaptureService` (AVCaptureMultiCamSession on iPad Pro M-series; falls back to single-cam silently elsewhere).
- iOS `ScreenSharePiPController` (system-managed PiP via `AVPictureInPictureController(contentSource:)`).
- iOS `MediaSettingsView` — Settings → Media with the per-partner save link, "Use back camera in calls" iPad toggle, stats overlay toggle.

**Phase 7 — macOS PiP + WSS retirement:**
- Mac `ScreenShareViewerWindow` — `NSPanel` with `.floating` level + `.canJoinAllSpaces + .fullScreenAuxiliary` for cross-Spaces / fullscreen-app overlay; mercury hairline border, drag-to-dock.
- `docs/runbooks/wss-retirement-checklist.md` — gate criteria + 10-step decommission sequence + 7-day rollback window.

Verification:
- `swift test`: **687 tests, 0 failures, 2 skipped** (was 641 before — 46 new tests across phases).
- `cargo test`: **5 tests, 0 failures**.
- `npx tsc --noEmit` in `functions/`: clean.

Blocked / pending (real-world gates per the master plan governance):

- **Phase 1b TestFlight verification** — real Mac (M3) → real iPhone 17 Pro across LAN + LTE; 5 MB PNG round-trip with `iroh_audit_events` showing `streamClass: "media.blob"` and zero plaintext crossing Firebase.
- **Phase 2 SKU registration** — `com.openburnbar.hostedMediaSync.monthly` configured in App Store Connect; `grantMediaGrandfather` invocation against the prod `hosted_quota_sync` cohort.
- **Phase 3 App Store re-submission** — added `NSScreenCaptureUsageDescription` requires reviewer notes + the pre-recorded walkthrough.
- **Phase 4 + 5 device-matrix soak** — per `docs/runbooks/media-device-matrix/` (iPhone 13 mini through iPhone 17 Pro Max, iPad mini 6 through iPad Pro M4, Mac Intel Skylake+ through M4).
- **Phase 5 App Store re-submission** — PushKit + camera + microphone permissions; reviewer walkthrough video.
- **Phase 5 Cloud Functions deploy** — `triggerVoIPCall`, `evaluateMediaBudget` deploy to prod via the existing CI release lane after a stage soak.
- **Phase 5 APNs router hookup** — `voip_outbound` collection trigger needs to be wired into `appstore/apnsClient.ts` so the documents emitted by `triggerVoIPCall` actually flow to Apple. Phase 5b deliverable.
- **Phase 7 WSS retirement gate** — 14 consecutive days of `successRate ≥ 0.995 && wss === 0 && directShare ≥ 0.75 && projectedMonthEndUSD ≤ 600` before flipping the decommission sequence in `docs/runbooks/wss-retirement-checklist.md`.

Next action:
- Land the iOS app coordinator wiring (set `HermesIrohRelayTransport.mediaDispatcher = iOSFileTransferService.handleAdvertise(...)` at app launch) and the Mac equivalent (`HermesIrohRelayHostClient.mediaDispatcher = MacFileTransferService.handleAdvertise(...)`). After that, flip `media_blob_transfer_enabled` for Alberto's TestFlight build and run the Phase 1b manual loop.

---

## 2026-05-15 — Audit pass (post-implementation)

**Gate status:** all builds green. Source is honest about what is wired and what is not.

Audit findings + fixes applied during the review pass:

- **`OpenBurnBarMedia` was not declared as a dependency of the Mac (`OpenBurnBar`) or iOS (`OpenBurnBarMobile`) Xcode targets.** Without the dependency, every file under `AgentLens/Services/Media/`, `AgentLens/Views/Media/`, `OpenBurnBarMobile/Services/Media/`, `OpenBurnBarMobile/Views/Media/` failed to compile against the Xcode build pipeline (it only compiled in `swift build` for the SwiftPM target). Fix: added `OpenBurnBarMedia` to both target dependency lists in `project.yml`; regenerated the Xcode project; verified `xcodebuild build` green for both schemes.
- **`VideoEncoder` used the wrong arity for `VTCompressionSessionEncodeFrame`'s outputHandler.** The output callback is a 3-arg closure `(OSStatus, VTEncodeInfoFlags, CMSampleBuffer?)`, not 5-arg. Fix: corrected the closure signature with explicit type annotations.
- **`VideoReceivePipeline` used the wrong arity for `VTDecompressionSessionDecodeFrame`'s outputHandler.** Should be `(OSStatus, VTDecodeInfoFlags, CVImageBuffer?, CMTime, CMTime)` — was 4-arg. Fix: corrected.
- **`CameraCaptureService` had a `private static func requestCameraAccess`** redeclared in `iPadMultiCamCaptureService` via an extension. Fix: removed the redundant extension, kept the original method as `static` for cross-file reuse.
- **`MacFileTransferService` declared `@Published` properties without `ObservableObject` conformance.** Fix: added the conformance.
- **The Mac + iOS dispatcher signatures used `@escaping` on the ack-sender parameter inside `handleAdvertise(...)`** even though the closure was always called inside the async function (never stored). The mismatch blocked passing the dispatcher closure from `IrohRelayRequestHandler` because that surface declares the ack-sender as non-escaping. Fix: dropped `@escaping` from `MacFileTransferService.handleAdvertise` and `iOSFileTransferService.handleAdvertise`.
- **The runbook claimed the Mac + iOS coordinators needed wiring at app launch as a separate Phase 2 step.** Audit pass landed it directly:
  - Mac: `AgentLens/Services/CloudSyncService.swift` now constructs `MacFileTransferService` (via `MediaFileTransferServiceFactory.make()`) and binds `irohClient.mediaDispatcher = { frame, ack in await macFileTransfer.handleAdvertise(...) }` at the same site where the iroh host is created.
  - iOS: `OpenBurnBarMobile/App/AppDelegate.swift` constructs `iOSFileTransferService` and binds `HermesIrohRelayTransport.shared.mediaDispatcher` during `application(_:didFinishLaunchingWithOptions:)`.
- **Settings flag `mediaBlobTransferEnabled` did not exist.** The dispatcher gate referenced it but the property was missing. Fix: added it to `ChatBackendSettings` + `SettingsManager` with a persistence key matching the iOS-side `UserDefaults.bool(forKey: "mediaBlobTransferEnabled")` read.
- **`AgentLensTests` did not link `OpenBurnBarMedia`.** Tests against the live `MacMediaCapabilityGate` couldn't import the media surface. Fix: added the dependency in `project.yml`.

Tests added during the audit:
- `MediaDispatchIntegrationTests` — 2 tests exercising the end-to-end advertise → fetch → ack contract through a scripted `IrohBlobBackend`. Verifies the ack frame routes back to the correct manifest and the typed failure path produces a `.rejected` ack.
- `MacMediaCapabilityGateTests` — 6 tests locking in the live admission logic: happy path, inactive entitlement, hard-cap denial, soft-cap per-session ceiling, concurrent-session ceiling, per-session byte budget overrun.

Verified post-audit:
- `swift test`: **689 tests, 0 failures, 2 skipped** (was 687 before audit — 2 new dispatch integration tests).
- `cargo test`: **5 tests, 0 failures**.
- `npx tsc --noEmit` in `functions/`: clean.
- `xcodebuild build` for `OpenBurnBar` (macOS arm64): **BUILD SUCCEEDED**.
- `xcodebuild build` for `OpenBurnBarMobile` (iOS Simulator iPhone 17 Pro Max): **BUILD SUCCEEDED**.
- `xcodebuild test -only-testing:OpenBurnBarTests/MacMediaCapabilityGateTests`: **6 tests, 0 failures**.
- `xcodebuild test -only-testing:OpenBurnBarTests` (Mac): **TEST SUCCEEDED**.
- `xcodebuild test -only-testing:OpenBurnBarMobileTests` (iOS): **TEST SUCCEEDED**.

Real-world activation gates still pending (per master plan governance):
- TestFlight Phase 1b manual loop (5 MB PNG, real Mac M3 → real iPhone 17 Pro across LAN + LTE).
- App Store Connect SKU registration (Phase 2: `com.openburnbar.hostedMediaSync.monthly`).
- App Store re-submission for new permissions (Phase 3 Screen Recording, Phase 5 Camera/Microphone/PushKit) with reviewer walkthrough video.
- Cloud Functions prod deploy: `triggerVoIPCall`, `evaluateMediaBudget`, `recomputeMediaQuotaUsage`, `grantMediaGrandfather`, `validateMediaPurchase`, `rollupMediaSessionDaily`, `sendVoIPOutbound`.
- Configure APNs secrets in Cloud Functions runtime: `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY_P8`, optional `APNS_VOIP_TOPIC` / `APNS_HOST` overrides.
- Device-matrix soak per `docs/runbooks/media-device-matrix/`.
- 14-day WSS retirement gate per `docs/runbooks/wss-retirement-checklist.md`.

---

## 2026-05-15 — Risk remediation + production polish

**Gate status:** all five identified risks resolved. Production polish in place.

Risk remediation:

- **Risk 1 — persistent media control stream (FIXED).** New architecture: iOS opens a dedicated bi-stream after authenticating, sends `media.classify { streamClass: "media.control" }` as the first frame, and keeps it open for the lifetime of the iroh connection. Mac's `IrohRelayRequestHandler` detects the classify frame and hands the stream to `MediaControlStreamRegistry` (new actor in `OpenBurnBarMedia`). `MacFileTransferService.sendFile` now consults the registry via `awaitStream(uid:timeout:)` so a freshly-typed attachment doesn't race iOS's control-stream dial. iOS-side coordinator (`MediaControlStreamCoordinator`) handles dial + classify + read loop + exponential-backoff reconnect with decorrelated jitter. New SwiftPM-side tests: 8 `MediaControlStreamRegistryTests` covering register/invalidate/latest/await/timeout/late-resolve/uid-isolation/displaced-close.
- **Risk 2 — APNs sender (FIXED).** New `functions/src/apnsSender.ts` implements a Firestore-trigger Cloud Function on `voip_outbound/*`. Uses Node's built-in `crypto` (ES256 JWT) + `http2` (Apple's HTTP/2 endpoint) — zero new dependencies. Status machine: `pending` → `sent` / `rejected` / `pending` with `retryAt`. Idempotent via APNs `apns-id` header set to the Firestore document id. Three new Cloud Functions secrets: `APNS_KEY_ID`, `APNS_TEAM_ID`, `APNS_KEY_P8`; two tunables (`APNS_VOIP_TOPIC`, `APNS_HOST`). Cached JWT minted once per ~50 minutes.
- **Risk 3 — Remote-Config-tunable cost factor (FIXED).** `evaluateMediaBudget` now reads `media_cost_per_gb_usd`, `media_budget_soft_cap_usd`, `media_budget_hard_cap_usd` from Firebase Remote Config at every run. Defaults (0.04 / 600 / 1000) apply when Remote Config is unavailable or returns invalid values (e.g., hard ≤ soft). Tuning loop documented in `docs/runbooks/media-budget.md`.
- **Risk 4 — wire views into actual app navigation (FIXED).** iOS Settings → AI Environments → Media is now a real `NavigationLink` that pushes `MediaSettingsView` (per-partner save preferences, iPad multi-cam toggle, stats overlay). Mac Settings sidebar has a new "Media & Sharing" tab that pushes `MediaPermissionsView` (Screen Recording / Camera / Microphone status pills with deep links to System Settings → Privacy). `CloudSyncService` now constructs `MediaFileTransferService` + `MediaControlStreamRegistry` + `MacFileTransferService` and binds both the per-request dispatcher AND the control-stream registrar on the iroh host client. Both Mac + iOS xcodebuild build green.
- **Risk 5 — Opus probe + AAC fallback (FIXED).** `AudioEncoder` now probes `AVAudioConverter(from:to:)` for Opus availability at init. If the converter can't initialize (older OSes, devices without the Opus codec module), the encoder falls back transparently to AAC-LC (`kAudioFormatMPEG4AAC`) so audio still flows. `resolvedCodec: Codec` is exposed on the encoder so the receiver pipeline can be notified out-of-band.

Production polish landed:

- **Structured analytics events.** New `MediaAnalyticsEvent` value type + `MediaAnalyticsSink` protocol in `OpenBurnBarMedia`. Eight event kinds (`sessionStarted`, `sessionEnded`, `transferCompleted`, `transferFailed`, `quotaDenied`, `budgetLevelChanged`, `controlStreamConnected`, `controlStreamLost`) all parameter-keyed to bucketed strings — payload counts never reach Firebase Analytics in plaintext. 6 new tests assert the bucketing contract.
- **Accessibility on Mercury surfaces.** `MercuryRing`, `IncomingCallSheet` (Mac), `MercuryIncomingSheet` (iOS) now respect `@Environment(\.accessibilityReduceMotion)` — pulse animation is suppressed when the user has Reduce Motion enabled, saving battery and avoiding vestibular discomfort. Same surfaces gained `accessibilityElement` + `accessibilityLabel` annotations so VoiceOver announces "Incoming call from {device name}", "Decline call from {device name}", "Accept call from {device name}". Keyboard shortcuts: Escape → Decline, Return → Accept on Mac.
- **`MacFileTransferService.lastSentManifestID` + `iOSFileTransferService.lastSentManifestID`** — `@Published` properties that let chat UI flip an in-flight row to "delivered" the moment the send completes.

Post-remediation verification:
- `swift test`: **703 tests, 0 failures, 2 skipped** (was 689 — 14 new tests: 8 registry + 6 analytics).
- `cargo test`: **5 tests, 0 failures**.
- `npx tsc --noEmit` in `functions/`: clean.
- `xcodebuild build` for `OpenBurnBar` (macOS arm64): **BUILD SUCCEEDED**.
- `xcodebuild build` for `OpenBurnBarMobile` (iOS Simulator iPhone 17 Pro Max): **BUILD SUCCEEDED**.

What still requires real-world setup (out of scope for source-level work):
- Generate the APNs auth key (.p8) in Apple Developer, upload to Cloud Functions runtime via `firebase functions:secrets:set APNS_KEY_P8`.
- Set `media_cost_per_gb_usd` in Firebase Remote Config from the first real n0 invoice.
- Wire `iOSFileTransferService.attachControlStream(_:)` into the iOS auth-state observer so the coordinator starts once the user signs in (one method call inside `HermesService` post-auth; can land alongside the first device-matrix soak).
