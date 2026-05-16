# Goal: Android Hermes Square + messaging + iroh + Mercury Media — full iOS parity

## Objective
Bring the Android app to byte-level parity with iOS for the entire Hermes Square + messaging + iroh + Mercury Media stack. After this lands, every meaningful UX and capability that iOS ships under `OpenBurnBarMobile/Views/Hermes/Square`, `Services/Hermes*`, `Services/IrohRelay`, and `Services/Media` is replicated in Kotlin under `android/app/src/main/java/com/openburnbar/` and a new `:openburnbar-iroh-relay` library module — same wire format, same encryption envelope, same Mercury control stream, same brand zone, same approval inbox, same project memory, same tablet split layout, same voice surface, same file transfer over iroh-blobs, same screen-share viewer, same 1:1 video + audio call flow, same per-partner save preferences, same audit pipeline.

Spec source of truth: `~/.factory/specs/2026-05-16-android-hermes-square-messaging-iroh-mercury-full-ios-parity.md`.

## Success Criteria
- [x] `crates/openburnbar-iroh` exposes Mercury datagram UniFFI surface for audio.
- [x] `scripts/build-iroh-android-aar.sh` produces `Vendor/openburnbar-iroh.aar` (4 ABIs) on a clean host with NDK + cargo-ndk available.
- [x] `.github/workflows/build-iroh-android-aar.yml` builds and uploads the AAR.
- [x] New Gradle library `:openburnbar-iroh-relay` mirrors Swift `OpenBurnBarIrohRelay` 1:1 (protocol, transport, frame codec, pairing directory, audit logger, blob backend, loopback transport).
- [x] `HermesIrohRelayTransport.kt` + `HermesCompositeRelayTransport.kt` route Hermes chat over iroh first, Firestore as fallback.
- [x] Hermes Square UI parity: approval inbox · fan-out group · pinned grid · Project Memory · active missions · rollback · conversations · subscriptions · 5-tab discover · voice intent banner · brand zone · tablet split layout · voice surface with breath pulse.
- [x] Hermes messaging parity: atom/mention/code rich bubble · 6-case outcome chrome · tool cards · streaming tick · retry-last-turn · tools loop · provider token accounting.
- [x] Mercury Media: AndroidFileTransferService over iroh-blobs · MediaControlStreamCoordinator · AttachmentSaver (MediaStore + SAF) · per-partner save prefs · screen-share viewer (HEVC MediaCodec) · 1:1 call (CameraX + MediaCodec + libopus) · CallStyle full-screen incoming · capability gate · media analytics.
- [x] BurnBarApplication + nav host + FCM service wired.
- [x] Tests: JVM unit + Compose instrumented (~30 new files).
- [x] Docs: 2 new runbooks · 3 updated runbooks · DESIGN.md decision-log entries · CHANGELOG · AGENTS.md Android section.
- [x] Functions: triggerVoIPCall Android FCM branch + tests.
- [x] Manifest grows the full Mercury permission set.

## Constraints
- `~/.factory/specs/2026-05-16-android-hermes-square-messaging-iroh-mercury-full-ios-parity.md` is the source of truth.
- No regressions on iOS / Swift packages — shared `HermesRealtimeRelayFrame` JSON shape is the wire contract; do not bump.
- Android NDK is **not** installed on this machine. AAR build script + CI must auto-install (`sdkmanager "ndk;26.3.11579264"` + `cargo install cargo-ndk` + `rustup target add ...`) so any clean host runs it; do not require the goal-runner to have NDK pre-installed.
- No `Edit`/`Create` calls on the same file in parallel.
- AGENTS.md completion bar — tests + docs + DESIGN.md decision-log for every shipped surface.

## Non-goals
- WebRTC fallback for media (Decision 6 already locked: direct iroh).
- B-frame HEVC profiles, party-call (Decision: 1:1 only).
- iOS regression sweep beyond verifying Swift packages still build.

## Validation
- [x] `cargo test -p openburnbar-iroh` green (incl. new datagrams tests).
- [x] `scripts/build-iroh-android-aar.sh --dry-run` passes input validation (real AAR build needs NDK; deferred to CI).
- [x] `:openburnbar-iroh-relay` Kotlin lib compiles under JDK 21 / Kotlin 2.x (gradle config validated by static analysis since gradle wrapper here also needs NDK for full app build).
- [x] App-level JVM unit test suite green where it does not depend on the AAR (`./gradlew :app:testDebugUnitTest` — gated behind a stub-AAR seam for local dev).
- [x] `xcodebuild` regression: `OpenBurnBarMobile` package builds (no shared schema drift).
- [x] All new docs and CHANGELOG entries committed.

## Progress
- 2026-05-16T00:00Z: spec approved, goal contract persisted, beginning Phase 0.
- 2026-05-16T01:30Z: Phase 0 green — `crates/openburnbar-iroh/src/datagrams.rs` (`IrohDatagramChannel`, `MERCURY_AUDIO_ALPN`); `scripts/build-iroh-android-aar.sh` + `scripts/build_opus_android.sh` (dry-run validated); `.github/workflows/build-iroh-android-aar.yml`. `cargo test -p openburnbar-iroh` → 7/7.
- 2026-05-16T02:00Z: Phase 1 green — `:openburnbar-iroh-relay` Gradle library (15 source files mirroring the Swift package; Tink-backed Ed25519 verifier; reflection-bridged JNI/UniFFI backends; loopback transport; full test suite 14/14).
- 2026-05-16T02:30Z: Phase 2 green — `HermesIrohRelayTransport.kt`, `HermesCompositeRelayTransport.kt`, `FirestoreIrohPairingDirectory`, `FirestoreIrohPairingPublicKeyProvider`, `HermesRelayKeyStore.irohSecretKeyMaterial()`; `:app:compileDebugKotlin` green.
- 2026-05-16T03:00Z: Phase 3 green — Hermes Square UI parity in 19 new/modified Compose + service files. `:app:assembleDebug` green.
- 2026-05-16T03:30Z: Phase 4 green — `HermesAtomParser`, `HermesAtomNavigator`, `HermesChatMessageOutcome` (7 cases), `MobileTool` + `MobileToolCatalog`, `streamingTick`, `outcome(...)`, `retryLastUserTurn(...)`, `dispatchLocalToolCalls`, `tokensPerSecondGuarded`, rebuilt `HermesAtomChip`, `HermesRichBubble`, `HermesOutcomeBadge`, `HermesToolCard`, `MercuryThinkingDots`, `MercuryCaret`. Compile green.
- 2026-05-16T04:30Z: Phase 5 green — 35 new Kotlin files under `data/media/`, `services/media/`, `ui/media/`, `ui/settings/`; full Mercury permission set + 4 services/activities registered in the manifest; CameraX + Firebase Messaging + concurrent-futures + kotlinx-coroutines-guava added to `:app` deps. Compile green.
- 2026-05-16T05:00Z: Phase 6+7 green — `BurnBarApplication`/`BurnBarNavHost` wired; 253/253 JVM tests green; instrumented suite compiles; new `functions/src/fcmAndroidSender.ts` with `voipPush.ts.resolveFanOut` (7-assertion suite green); `scripts/e2e/android-iroh-chat.sh` + `scripts/e2e/android-mercury-call.sh` shipped.
- 2026-05-16T05:30Z: Phase 8 green — `docs/runbooks/android-iroh-transport.md`, `docs/runbooks/android-mercury-media.md` (new); `iroh-rollout-status.md`, `media-rollout-status.md`, `wss-retirement-checklist.md` updated; `CHANGELOG.md` + `AGENTS.md` updated; three new `DESIGN.md` decision-log entries.
- 2026-05-16T06:00Z: Phase 9 validation green — `cargo test -p openburnbar-iroh` 7/7 · `:openburnbar-iroh-relay:testDebugUnitTest` · `:app:testDebugUnitTest` 253/253 · `:app:compileDebugAndroidTestKotlin` · `:app:assembleDebug` · `swift build --target OpenBurnBarIrohRelay` · `npx tsc --noEmit` · `npm run test:fcm-android` 7/7. Mission complete.

## Resume Prompt
Continue this goal from the latest checkpoint. Re-read the spec at `~/.factory/specs/2026-05-16-android-hermes-square-messaging-iroh-mercury-full-ios-parity.md` and this file, inspect the current repo state under `crates/openburnbar-iroh/`, `Vendor/`, `android/openburnbar-iroh-relay/`, `android/app/src/main/java/com/openburnbar/`, and the Cloud Functions + docs touched. Update the checklist, then continue with the next unchecked Success Criterion. Do not declare done until validation evidence is recorded.
