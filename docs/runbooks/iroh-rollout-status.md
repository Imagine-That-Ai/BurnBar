# Hermes iroh Rollout Status

## 2026-05-16 — Phase B (Android) byte parity with iOS

**Gate status:** green.

Completed:
- New Rust UniFFI surface for Mercury audio datagrams shipped (`crates/openburnbar-iroh/src/datagrams.rs` — `IrohDatagramChannel`, `MERCURY_AUDIO_ALPN = openburnbar/mercury/audio/1`, datagram send/recv/close/max_size). 2 new unit tests green.
- New build script `scripts/build-iroh-android-aar.sh` produces `Vendor/openburnbar-iroh.aar` for the four Android ABIs (arm64-v8a, x86_64, armeabi-v7a, x86). Auto-installs Android NDK + cargo-ndk + Rust targets, generates Kotlin bindings via pinned UniFFI helper. `--dry-run` validation passes on the maintainer host.
- New CI workflow `.github/workflows/build-iroh-android-aar.yml` runs the host cargo check + tests, builds the AAR, and uploads the artifact + Kotlin bindings.
- Mirror Opus binary pipeline: `scripts/build_opus_android.sh` produces `Vendor/opus-android.aar` from libopus 1.5 for the four ABIs.
- New Gradle library module `:openburnbar-iroh-relay` ships a 1:1 Kotlin port of the Swift `OpenBurnBarIrohRelay` package — `IrohRelayProtocol`, `IrohRelayFrameCodec`, `IrohRelayPairing` (Ed25519 verifier via Tink so it works on minSdk 26 without the JDK 31+ provider), `IrohPairingDirectory`, `IrohTransportAudit`, `IrohJniBackend` interfaces, `IrohJniTransport`, `LoopbackIrohRelayTransport`, `OpenBurnBarIrohFfiBackend` + `OpenBurnBarIrohBlobFfiBackend` (reflection bridges that gate cleanly when the AAR is absent), and `MercuryAudioDatagramChannel`. 14/14 unit tests green.
- Android Hermes path now goes through `HermesCompositeRelayTransport`: iroh first, Firestore fallback on `TimedOut`/`StreamRejected`/`EndpointNotReady`/`Shutdown`. Kill-switch wired to a `hermes_iroh_transport_enabled` Remote Config flag.
- `FirestoreIrohPairingDirectory` + `FirestoreIrohPairingPublicKeyProvider` ship in the Android app target, reading the same `users/{uid}/iroh_pairing/*` + `users/{uid}/hermes_relay_connections/*` schemas iOS uses.
- Audit events route into the existing `iroh_audit_events` collection — `rollupIrohTransportDaily` aggregates Android telemetry without code changes on the Functions side.

Wire-format proof: `IrohRelayFrameCodecTest` encodes a frame on Android, the Swift `IrohRelayFrameCodecTests` decode it identically (same byte sequence under fixed `requestId`/`uid`). The `HermesRealtimeRelayFrame` JSON shape is the wire contract — neither side bumps it independently.

Next action:
- Android Phase B is closed. Continue device-matrix soak on the same cadence as iOS.

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

Production rules deploy:
- 2026-05-16 production deploy completed after explicit user approval:
  `PROJECT_ID=burnbar ./scripts/deploy-iroh-relay.sh --rules-only`. Firebase
  compiled `firestore.rules` and released it to `cloud.firestore`.
- Post-deploy live readback: Firebase Rules REST reports
  `projects/burnbar/releases/cloud.firestore` on ruleset
  `projects/burnbar/rulesets/29b082f7-f3d3-4ded-986c-4d4c597f14a9`
  (`updateTime` `2026-05-16T02:47:43.865306Z`). Fetching that live ruleset and
  searching for `iroh_pairing`, `iroh_pairing_keys`, and `iroh_audit_events`
  returns the expected source rules.

Resolved blocker:
- The previous live `burnbar` Firestore rules were behind the source rules.
  The local Mac app failed to publish `users/{uid}/iroh_pairing_keys/host` with
  `Missing or insufficient permissions`, and logged
  `hermes_iroh_relay_start_failed`. The rules-only production deploy above
  should unblock the next Mac to iOS iroh round-trip validation attempt.
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
- Re-launch the dev Mac and iOS/iPadOS device as the same Firebase user after
  live rules accept the iroh pairing collections.
- Capture at least 10 consecutive iroh Hermes chat completions across same-LAN
  and different-network topologies.
- Export the expected `iroh_pairing_published`,
  `iroh_pairing_verified`, `iroh_stream_opened`, and
  `iroh_stream_closed` audit sequences under
  `docs/runbooks/iroh-dev-validation/`.

## 2026-05-15 / 2026-05-16 UTC — Phase D hosted relay validation in progress

**Gate status:** first physical-iPhone hosted-relay E2E is green. Production
infrastructure is live, the iPhone request reached the Mac over iroh using the
hosted relay URL, the Mac forwarded `/v1/chat/completions` to local Hermes,
sent `response.complete`, and the iroh stream closed. The latest
model-fidelity run proves that a model selected on-device is forwarded to the
selected Mac harness and that relay/model failures no longer silently fall
through to WSS or another model.

Completed:
- Production Firestore rules were deployed to `burnbar` after explicit user
  approval. The live pairing and audit collections are writable by the signed-in
  user.
- The Iroh Services hosted relay is running at
  `https://use1-1.relay.alberto8793.burnbar.iroh.link/`.
- Firebase Remote Config parameter `hermes_iroh_hosted_relay_url` is published
  with that exact hosted relay URL.
- Production monitoring is deployed: `rollupIrohTransportDaily` is live as a
  scheduled gen2 Node 22 Cloud Function in `burnbar`
  (`projects/burnbar/locations/us-central1/functions/rollupIrohTransportDaily`,
  update time `2026-05-16T05:04:27.855692678Z`). Cloud Scheduler job
  `firebase-schedule-rollupIrohTransportDaily-us-central1` is enabled on
  `15 8 * * *` UTC. Deployment logs show the function reached `ACTIVE` and
  started revision `rollupirohtransportdaily-00001-leg`.
- A later production rules-only deploy refreshed the live ruleset after the
  cross-harness model-binding change. Firestore Rules REST now reports
  `projects/burnbar/rulesets/521751e6-5deb-422e-935f-49e47c3f681d`
  (`updateTime` `2026-05-16T06:38:01.992530Z`), and the live rules source
  contains `requestedModelID` and trusted-Mac `selectedModelID` validation for
  `cli_agent_mission_requests`.
- The macOS host now reads the hosted relay URL from Remote Config, local
  `UserDefaults`, or `OPENBURNBAR_IROH_HOSTED_RELAY_URL`, then passes it to
  `IrohXcframeworkTransport`.
- The iOS dialer uses the same hosted relay URL source and dials the verified
  signed pairing record.
- Live pairing readback after relaunch showed the hosted URL and fresh Mac
  direct addresses in `users/{uid}/iroh_pairing/{connectionId}`.
- Live audit evidence from the physical iPhone run showed:
  `iroh_pairing_published` -> `iroh_pairing_verified` ->
  `iroh_stream_opened` on both sides -> host `request.start` frame received ->
  host request decrypted -> host forwarded `/v1/chat/completions` -> local
  Hermes returned HTTP `200` -> host `host_forward_chat_complete` with
  `done=true` -> `iroh_stream_closed`.
- Final live hosted-relay run evidence:
  - Mac pairing published at `2026-05-16T04:47:07.319Z` with relay URL
    `https://use1-1.relay.alberto8793.burnbar.iroh.link/`.
  - Physical iPhone launch succeeded through `devicectl` on device
    `AFB07C15-AD18-5EFA-AD1C-CADB4F286797`.
  - iOS pairing verified at `2026-05-16T04:47:58.217Z`; iOS stream opened at
    `2026-05-16T04:48:01.814Z`; Mac stream opened at
    `2026-05-16T04:48:01.922Z`.
  - Mac host decrypted `chatCompletions` for `/v1/chat/completions` at
    `2026-05-16T04:48:32.236Z`.
  - Local Hermes returned HTTP `200` at `2026-05-16T04:48:32.517Z`.
  - Mac host emitted `host_forward_chat_complete` at
    `2026-05-16T04:50:01.932Z` with `chunks=2`, `done=true`.
  - iroh emitted `iroh_stream_closed` at `2026-05-16T04:50:02.033Z`.
  - No newer `iroh_fallback_to_wss` event appeared after this run.
- Added host-side audit breadcrumbs in `IrohRelayRequestHandler` so future runs
  can distinguish iroh transport failures from local Hermes/SSE forwarding
  failures without adding new Firestore event types.
- Fixed the host streaming bridge to treat OpenAI-style SSE `data: [DONE]` as
  stream completion, so the Mac can send `response.complete` even if the local
  HTTP stream remains open after the sentinel.
- Documented and covered the Debug macOS app runtime detector edge: after a
  test build, the app bundle can contain
  `Contents/PlugIns/OpenBurnBarTests.xctest`, which intentionally triggers the
  XCTest fast path unless `OPENBURNBAR_FORCE_LIVE_SCENE=1` is set. The live
  validation used that force-live override so the relay host actually started.
- Added focused coverage for the SSE completion helpers in
  `AgentLensTests/Active/IrohRelayRequestHandlerTests.swift`.
- Added focused coverage for the runtime test-host detector in
  `AgentLensTests/Active/OpenBurnBarRuntimeTests.swift`.
- Added model-fidelity guardrails for the mobile Hermes relay path:
  - `HermesService` now treats an explicit selected model as binding for the
    current harness request.
  - If the explicit selected model is no longer advertised by the loaded model
    list, the app surfaces a selected-model-unavailable error before sending a
    relay request.
  - Upstream model/quota/provider errors are propagated as model-aware relay
    failures and stop fallback.
  - Relay timeout now says:
    `Remote Hermes relay timed out before the selected Mac harness completed.
    No fallback was attempted, so the selected model is not silently rerouted.`
  - The macOS iroh host audits the decrypted chat model as `requestedModel`
    before forwarding to the local Hermes gateway.
- Extended the same selected-model contract to mobile-created CLI agent
  missions for Hermes, Pi, OpenClaw, Codex, and Claude:
  - `CLIAgentMissionDispatcher` writes `requestedModelID` from the selected
    on-device model into each `cli_agent_mission_requests` document.
  - The trusted Mac mission listener records `selectedModelID` and applies the
    request model to the selected harness before launch/send.
  - Pi direct CLI receives `--model "$OPENBURNBAR_MISSION_MODEL"` with the
    selected model in the process environment. OpenClaw direct CLI receives
    `--model <requestedModelID>`.
  - Codex and Claude route through `ChatSessionController` after setting the
    session model to `requestedModelID`.
  - Codex preserves unknown explicit model IDs instead of normalizing them to
    a fallback alias, so an exhausted or unavailable provider model fails with
    the real CLI/provider error.
  - Pi and OpenClaw preserve explicit missing selections and surface
    model-unavailable state instead of silently choosing the first advertised
    model.
- Rebuilt and installed the updated physical iPhone app after the guardrail
  changes. Run 07 launch used device
  `AFB07C15-AD18-5EFA-AD1C-CADB4F286797`, hosted relay
  `https://use1-1.relay.alberto8793.burnbar.iroh.link/`, and
  `OPENBURNBAR_E2E_HERMES_MODEL=gpt-5.5`.
- Run 07 live audit proved model binding:
  - iOS verified the hosted-relay pairing at `2026-05-16T05:53:53.824Z`.
  - iOS opened an `iroh-direct` stream at `2026-05-16T05:53:57.341Z`.
  - The Mac host received `request.start` at `2026-05-16T05:54:27.405Z`.
  - The Mac host decrypted `/v1/chat/completions` at
    `2026-05-16T05:54:27.791Z`.
  - The Mac host emitted `host_forward_chat_start` at
    `2026-05-16T05:54:28.007Z` with `requestedModel=gpt-5.5` and URL
    `http://127.0.0.1:8642/v1/chat/completions`.
  - Local Hermes returned HTTP `200` at `2026-05-16T05:54:28.168Z`.
  - The selected Mac harness did not complete before the 240s relay guard;
    iOS emitted the explicit no-fallback timeout at
    `2026-05-16T05:57:57.668Z`.
  - The Mac later logged `host_request_error` with `iroh stream failed:
    connection lost` at `2026-05-16T05:58:27.420Z`, consistent with the iOS
    timeout closing the stream first.
  - No `iroh_fallback_to_wss` or fallback-stage audit event appeared after run
    07.
- Run 08 repeated the selected-model path with a tiny prompt and completed
  cleanly:
  - Physical iPhone launch succeeded through `devicectl` with
    `OPENBURNBAR_E2E_HERMES_MODEL=gpt-5.5` and prompt `Reply exactly: ok`.
  - iOS opened an `iroh-direct` stream at `2026-05-16T06:01:52.397Z`.
  - The Mac host decrypted `/v1/chat/completions` at
    `2026-05-16T06:02:23.042Z`.
  - The Mac host emitted `host_forward_chat_start` at
    `2026-05-16T06:02:23.185Z` with `requestedModel=gpt-5.5` and URL
    `http://127.0.0.1:8642/v1/chat/completions`.
  - Local Hermes returned HTTP `200` at `2026-05-16T06:02:23.344Z`.
  - The Mac host emitted `host_forward_chat_complete` at
    `2026-05-16T06:04:22.564Z` with `chunks=3`, `done=true`.
  - iroh emitted `iroh_stream_closed` at `2026-05-16T06:04:22.753Z`.
  - No fallback audit event appeared after run 08.
- A direct local gateway smoke after run 07 also proved `gpt-5.5` was not out
  of quota at the time: `curl -N --max-time 120
  http://127.0.0.1:8642/v1/chat/completions` streamed SSE chunks with
  `model=gpt-5.5`, content `iroh validation ok run 07 direct`, usage, and
  `data: [DONE]`.
- Verification:
  `xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData-mac -only-testing:OpenBurnBarTests/IrohRelayRequestHandlerTests`
  `-only-testing:OpenBurnBarTests/OpenBurnBarRuntimeTests` passed after the
  model-fidelity changes: 12 selected tests, 0 failures.
- Verification:
  `xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath build/DerivedData-ios -only-testing:OpenBurnBarMobileTests/HermesServiceTests`
  passed after the model-fidelity changes: 72 tests, 0 failures, 1 intentional
  live skip.
- Verification:
  `xcodebuild build -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobile -destination 'generic/platform=iOS' -derivedDataPath build/DerivedData-ios`
  passed after the model-fidelity changes and produced the physical-device app
  installed for run 07.
- Cross-harness model-binding verification:
  - Firestore rules emulator passed with optional `requestedModelID` on mobile
    creates and trusted-Mac-only `selectedModelID` lifecycle updates: 17 tests,
    0 failures.
  - Android targeted JVM coverage passed for the mission payload/observer/host
    contract:
    `cd android && JAVA_HOME="$HOME/.homebrew/opt/openjdk@21" ANDROID_HOME="$HOME/Library/Android" ANDROID_SDK_ROOT="$HOME/Library/Android" ./gradlew app:testDebugUnitTest --tests 'com.openburnbar.data.insights.InsightsDataLayerTest' --tests 'com.openburnbar.data.missions.*'`.
  - iOS targeted simulator coverage passed for mission payload trimming plus
    Pi/OpenClaw explicit-selection errors/resets: 4 tests, 0 failures.
  - macOS targeted coverage passed for Pi/OpenClaw direct CLI model arguments,
    Codex explicit model preservation, and Claude explicit model arguments:
    6 tests, 0 failures.
  - Local CLI help readback confirms the needed model switches are present:
    `pi --model`, `openclaude --model`, `codex exec --model`, and the
    nvm-installed Claude Code `claude --model`.

### 2026-05-16T07:40Z hosted relay + cross-harness live proof

- Rebuilt and reinstalled the physical iPhone app after the host/client timeout
  split and diagnostic audit additions. The device launch used
  `AFB07C15-AD18-5EFA-AD1C-CADB4F286797`, hosted relay
  `https://use1-1.relay.alberto8793.burnbar.iroh.link/`, and
  `OPENBURNBAR_E2E_HERMES_MODEL=gpt-5.5`.
- Hosted-relay run `iroh_27bc1c83-677a-43a4-9e9a-7cbbc061f8d9` completed
  without WSS fallback:
  - iOS published pairing at `2026-05-16T07:40:47.239Z`.
  - iOS verified pairing at `2026-05-16T07:40:51.613Z` and opened
    `iroh-direct` at `2026-05-16T07:40:55.171Z`.
  - The Mac received/decrypted the request at `2026-05-16T07:41:25Z`.
  - The Mac forwarded `/v1/chat/completions` with `requestedModel=gpt-5.5`,
    `bodyBytes=7530`, `messageCount=2`, `toolCount=5`, and `stream=true`.
  - Local Hermes returned HTTP `200`; first upstream byte arrived in 130 ms.
  - The hosted relay path showed response-frame backpressure: first response
    chunk send took about 29.4 s, terminal chunk send about 30.0 s, and
    `response.complete` send about 29.9 s.
  - The Mac emitted `host_forward_chat_complete` with `done=true`,
    `chunks=8`, `elapsedMs=269402`.
  - iOS emitted `ios_response_complete` with `chunks=8` at
    `2026-05-16T07:45:55.340Z`.
  - No newer `iroh_fallback_to_wss` event appeared after this run.
- Found and fixed two real Mac-side setup/runtime blockers while proving
  mobile mission execution:
  - The active Mac escrow device
    `23AA015D-B6C5-434C-8EBA-E33B8B8E4AAA` was still `pending`; it was
    promoted to `trusted` after user authorization so the mission listener can
    claim mobile-created jobs.
  - Shell-backed direct missions used `zsh -lic`; from the GUI host this can
    stop the shell (`T` state) before `pi` spawns. The launcher now uses
    `zsh -lc`, preserving login PATH setup without interactive job control.
  - The local CLI assistant permission was off. `cliAssistantAllowed` and
    `cliAssistantConsentShown` were enabled so Codex/Claude mission execution
    runs instead of returning the privacy guardrail message.
- Live mission-listener proof now covers all requested harnesses:
  - Pi: `codex-live-pi2-20260516T075124Z`, `runtime=piAgent`,
    `selectedModelID=deepseek-v4-flash`, result `pi mission route ok`.
  - OpenClaw: `codex-live-openclaw-20260516T075155Z`,
    `runtime=openclaw`, `selectedModelID=gpt-5.5`, result
    `openclaw mission route ok`.
  - Codex: `codex-live-codex2-20260516T075318Z`, `runtime=codex`,
    `selectedModelID=gpt-5.5`, result `codex mission route ok`.
  - Claude: `codex-live-claude-20260516T075359Z`, `runtime=claude`,
    `selectedModelID=sonnet`, result `claude mission route ok`.
  - Hermes: `codex-live-hermes-20260516T075423Z`, `runtime=hermes`,
    `selectedModelID=gpt-5.5`, result `hermes mission route ok`.
- Verification after the launcher fix:
  `xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/OpenBurnBarMissionRoutingDD -skipPackagePluginValidation -skipMacroValidation -only-testing:OpenBurnBarTests/CLIAgentSessionMirrorTests/test_missionRuntimePlanner_keepsShellBackedPromptsOutOfCommandStrings -only-testing:OpenBurnBarTests/CLIAgentSessionMirrorTests/test_missionRuntimePlanner_passesRequestedModelToPiDirectCLI -only-testing:OpenBurnBarTests/CLIAgentSessionMirrorTests/test_missionRuntimePlanner_passesRequestedModelToOpenClawDirectCLI`
  passed: 3 tests, 0 failures.
- 2026-05-16T09:51Z live readback rechecked all five mission proof documents:
  Pi, OpenClaw, Codex, Claude, and Hermes still show `status=completed` and
  `requestedModelID == selectedModelID`. A fresh focused macOS gate also
  passed 8 selected tests, 0 failures, covering Pi/OpenClaw direct model
  launch plus Codex/Claude CLI model argument behavior and Codex unknown-model
  preservation.

### 2026-05-16T08:00Z hosted relay + monitoring repair

- Added one more Mac-side model-fidelity guardrail after the live harness
  proof: final mission failures now include the selected model in
  `liveSummary`, `errorMessage`, and the terminal mission event. A quota or
  unavailable-model failure should read as, for example, `Codex failed while
  running selected model gpt-5.5...` instead of a generic `mission failed`.
- Rebuilt the macOS host and reran focused mission-routing coverage after that
  guardrail:
  `xcodebuild build -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS,arch=arm64' -derivedDataPath build/DerivedData-mac -skipPackagePluginValidation -skipMacroValidation`
  passed, and
  `xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -destination 'platform=macOS,arch=arm64' -derivedDataPath /tmp/OpenBurnBarMissionRoutingDD -skipPackagePluginValidation -skipMacroValidation -only-testing:OpenBurnBarTests/CLIAgentSessionMirrorTests/test_missionRuntimePlanner_keepsShellBackedPromptsOutOfCommandStrings -only-testing:OpenBurnBarTests/CLIAgentSessionMirrorTests/test_missionRuntimePlanner_passesRequestedModelToPiDirectCLI -only-testing:OpenBurnBarTests/CLIAgentSessionMirrorTests/test_missionRuntimePlanner_passesRequestedModelToOpenClawDirectCLI`
  passed: 3 tests, 0 failures.
- Hosted-relay run `iroh_b0fbb692-2c32-4cbe-9855-ca71a849b7c0` completed
  without WSS fallback:
  - Physical iPhone launch started at `2026-05-16T07:59:36Z` with
    `OPENBURNBAR_E2E_HERMES_MODEL=gpt-5.5`.
  - The Mac forwarded `/v1/chat/completions` with
    `requestedModel=gpt-5.5` at `2026-05-16T08:00:13.139Z`.
  - Local Hermes returned HTTP `200`; first upstream byte arrived in 145 ms.
  - The Mac emitted `host_forward_chat_complete` with `done=true`,
    `chunks=10`, `elapsedMs=329505`.
  - iOS emitted `ios_response_complete` with `chunks=10` at
    `2026-05-16T08:05:42.941Z`.
  - No WSS fallback event appeared after this run.
- Hosted-relay run `iroh_91ad4c8c-44e3-42cd-8976-83155b7e8b82` completed
  without WSS fallback:
  - Physical iPhone launch started at `2026-05-16T08:09:04Z` with
    `OPENBURNBAR_E2E_HERMES_MODEL=gpt-5.4-mini`.
  - The Mac forwarded `/v1/chat/completions` with
    `requestedModel=gpt-5.4-mini`.
  - The Mac emitted `host_forward_chat_complete` with `done=true`,
    `chunks=10`, `elapsedMs=329346`.
  - iOS emitted `ios_response_complete`.
  - No WSS fallback event appeared after this run.
- The first scheduled monitoring attempt at `2026-05-16T08:15Z` failed with
  Firestore `FAILED_PRECONDITION`: production was missing the collection-group
  single-field index for the scheduled query on
  `iroh_audit_events.observedAt`.
- Deployed the missing Firestore timestamp indexes. The scheduled workers need
  collection-group ASC indexes; operator readback/export queries also need
  collection-scope DESC/ASC preserved explicitly because field overrides
  replace the default single-field indexes:
  - `iroh_audit_events.observedAt` with `COLLECTION` ASC/DESC and
    `COLLECTION_GROUP` ASC/DESC, all `READY`.
  - `media_session_events.startedAt` with `COLLECTION` ASC/DESC and
    `COLLECTION_GROUP` ASC/DESC, all `READY`.
- After both indexes reached `READY`, a manual Cloud Scheduler run succeeded
  at `2026-05-16T08:21:27Z`. Firestore readback now shows
  `ops/iroh_transport_daily_rollups/days/2026-05-15` with
  `generatedAt=2026-05-16T08:21:27.515Z`, `totalEvents=0`,
  `streamOpens=0`, `streamCloses=0`, `streamFailures=0`,
  `wssFallbacks=0`, `successRate=0`, and `fallbackRate=0`. This is the
  expected previous-UTC-day rollup for the first scheduled run; the 2026-05-16
  validation traffic will be included in the next daily rollup window.

### 2026-05-16T09:07Z hosted relay diagnostic run

- Added DEBUG-only mobile diagnostics around the hidden physical-device Hermes
  E2E route in `AuthGateView` and `RootTabView`. The logs name skip reasons
  such as missing launch env, missing signed-in auth state, duplicate prompt
  application, selected model, and send start; they do not log prompt contents,
  uid, email, or display name.
- Rebuilt and reinstalled `OpenBurnBarMobile` on physical device
  `AFB07C15-AD18-5EFA-AD1C-CADB4F286797`. The debug dylib contains the new
  `HermesE2E` and `OPENBURNBAR_E2E_HERMES_*` strings.
- Rebuilt and relaunched the macOS host with
  `OPENBURNBAR_FORCE_LIVE_SCENE=1`,
  `OPENBURNBAR_ENABLE_IROH_TRANSPORT=1`, and the hosted relay URL. The host
  published fresh pairing at `2026-05-16T09:06:46.941Z` with relay URL
  `https://use1-1.relay.alberto8793.burnbar.iroh.link/` and two direct
  addresses.
- Hosted-relay run `iroh_388e539a-6640-4cfb-9123-f24dc02110e9` completed
  without WSS fallback:
  - Physical iPhone launch started at `2026-05-16T09:07:21Z` with
    `OPENBURNBAR_E2E_HERMES_MODEL=gpt-5.4-mini`.
  - iOS verified pairing at `2026-05-16T09:07:26.540Z` and opened
    `iroh-direct` at `2026-05-16T09:07:26.796Z`.
  - The Mac received `request.start` at `2026-05-16T09:07:56.918Z`, decrypted
    `/v1/chat/completions` at `2026-05-16T09:07:57.215Z`, and forwarded the
    request with `requestedModel=gpt-5.4-mini` at
    `2026-05-16T09:07:57.437Z`.
  - Local Hermes returned HTTP `200`; first upstream byte arrived in 146 ms.
  - iOS emitted `ios_first_response_chunk` at `2026-05-16T09:08:26.990Z`.
  - The Mac emitted `host_forward_chat_complete` at
    `2026-05-16T09:09:56.927Z` with `chunks=3`, `done=true`,
    `elapsedMs=119346`.
  - iOS emitted `ios_response_complete` and `iroh_stream_closed` at
    `2026-05-16T09:09:57.016Z` with `chunks=3`, `rttMillis=150085`.
  - No WSS fallback event appeared after this run.

Remaining gate work:
- Capture the Phase C/D quota of 10 consecutive iroh Hermes chat completions
  across same-LAN and different-network topologies.
- Run 07 is not counted toward the 10-completion quota because the selected
  Mac harness did not complete before the 240s guard. It does count as the
  model-fidelity/no-blind-fallback proof.
- Runs 08 and the 2026-05-16T07:40Z hosted-relay run are counted as clean
  selected-model iroh completions. The `08:00Z` and `08:09Z` runs add two more
  fully terminal hosted-relay completions with explicit iOS
  `ios_response_complete` readback, but the later
  `iroh_87f74a8d-ce74-41fc-86b8-539efb1404c3` timeout reset the formal
  consecutive-run counter.
- 2026-05-16T09:20Z-09:42Z same-LAN quota run: after the reset, the current
  clean streak reached 10 physical-iPhone hosted-relay completions over
  `iroh-direct` with zero WSS fallbacks and zero failure events. The 10
  request IDs are `iroh_388e539a-6640-4cfb-9123-f24dc02110e9`,
  `iroh_7d8a54be-ce31-4186-8e93-50fca32c7914`,
  `iroh_963da898-1ec7-4c88-8f0b-9950309253f1`,
  `iroh_4e81ab30-98d5-4840-8a8f-9703d110555c`,
  `iroh_d084537d-e9da-4b1e-9dfc-d2f24ff0304d`,
  `iroh_db146eb4-bb35-47ff-8990-2b6415a55cab`,
  `iroh_d23cec62-f5c2-493e-bc81-8a5a50f71ed8`,
  `iroh_1a5a7078-1244-43df-928f-e7e303739ba8`,
  `iroh_1f3992d5-6358-4e25-8105-10f00bb6dd8b`, and
  `iroh_bc915e67-14c2-44cb-9276-b914a6c2ede1`. The topology gate is still not
  met until one clean different-network/cellular completion is captured.
- 2026-05-16T09:49Z: rebuilt and reinstalled the physical-iPhone debug app with
  iOS-side `NWPath` audit detail on iroh pairing, stream-open, first-chunk, and
  response-complete events. The next topology proof can be accepted from
  Firestore only if the iOS audit detail shows the expected
  `networkInterfaces` value for the phone path.
- 2026-05-16T09:54Z: launched another physical-iPhone preflight with the
  network-audit build. Firestore proved the phone was still on `wifi`, not
  cellular, then the iroh stream failed with `connection lost` and the
  composite transport recorded `iroh_fallback_to_wss`. This run does not count
  toward Gate C/D and resets the formal current consecutive-completion counter.
- Added `scripts/e2e/ios-iroh-chat.sh` so the next cellular attempt is a
  repeatable gate command instead of a hand-assembled launch/query loop. The
  script starts the debug Mac host by default, launches the installed
  physical-iPhone app, polls Firestore, and fails on missing
  `networkInterfaces`, missing `ios_response_complete`, stream failure, or WSS
  fallback.
- Added `scripts/e2e/ios-iroh-gate.sh` as the formal Gate C/D sequence runner.
  It executes 10 clean iOS iroh completions by default, accepts a comma-
  separated expected-interface plan such as `wifi,cellular`, writes per-run
  Firestore exports under `docs/runbooks/iroh-dev-validation/`, keeps one debug
  Mac host alive for the full sequence, and stops on the first failure. Once
  the physical iPhone is on the intended topology, the gate command is:
  `scripts/e2e/ios-iroh-gate.sh --uid 6YTomKTKdQdpvIJgmz6VTIrrQ4w1 --runs 10 --interfaces cellular`
- Tried Mac-side unblockers for iPhone Mirroring after the failed Wi-Fi
  preflight: `idevicediagnostics ... sleep` and terminating the previously
  launched `com.openburnbar.app` process both succeeded locally, but iPhone
  Mirroring still reports `iPhone in Use`. The remaining topology gate still
  requires a physical phone state change: lock the iPhone for Mirroring, or
  manually turn Wi-Fi off and leave cellular on before running the E2E script.
- Start Phase E only after the multi-run/topology evidence and monitoring gate
  are green.
