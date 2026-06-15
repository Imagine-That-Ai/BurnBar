# SOTASIGNAL - Remaining Work Handoff

**Date:** 2026-06-05
**Repo:** `/Users/albertonunez/Documents/Windsurf/BurnBar`
**Branch/worktree:** `signal/phase2`, dirty tree with completed implementable Signal work
**Read first:** `docs/signalification/SKEPTICAL_ADVERSARIAL_REVIEW_HANDOFF.md` and `.agent/runs/sotasignal-full-ship-20260605/evidence/final-validation.md`

This handoff is for the next operator after the SOTASIGNAL implementation pass. The flag-OFF safety/proof layers in this checkout are done and verified. The remaining work is the activation path: some gates require humans or reachable hardware, and some are still code/runtime work (production producer rollout, remaining identity/revocation wiring, telemetry, and live E2E).

Do not claim 10/10, GA-ready, or production-activated until every gate below is closed with durable evidence.

---

## Current Truth

Implemented and green in the current dirty tree:

- Native L37 relocation hardening is complete: Swift and Android openers require caller-derived `expectedBinding`, compare it unconditionally, and derive AAD from `expectedBinding`.
- Swift AAD reserved-character guard is scalar-level, not grapheme-level.
- Firestore at-rest Signal envelope validators are wired for the direct-write collections and path-bound to doc coordinates.
- Admin at-rest Signal validator exists and is tested, but is not yet wired to a production writer because production Signal writes are still flag-OFF.
- L41 v1 `signal_identity_public_keys` rules are green.
- Data export Signal sanitizer fails closed on malformed signal-shaped values.
- User-facing "server searches without reading it" style over-claims were rewritten to caveated copy across website, macOS, iOS, Android, and generated trust/domain outputs.
- Phase-F scripts exist: crypto proof harness, activation parity, Rule-0 guard, honesty gate, rollback drill.
- Apple Signal FFI packaging was rebuilt from script, Swift Signal at-rest tests pass against it, the full mobile unit suite passed on a connected physical iPhone, focused mobile assistant chat + CLI mission Signal path-binding tests passed on that physical iPhone, final focused iPad Pensieve/chat Signal tests passed on the wired iPad, and the Android physical Signal instrumented suite passed on a connected Galaxy S24. Evidence: `.agent/runs/sotasignal-full-ship-20260605/evidence/device-packaging/physical-device-packaging-status.md` and `.agent/runs/sotasignal-full-ship-20260605/evidence/physical-device-final-20260605.md`.

Latest claimed green proof matrix:

```bash
cd functions && npx tsc --noEmit
cd functions && npx vitest run
cd functions && npm run test:firestore-rules
cd packages/signal-envelope-contracts && npm test
cd packages/libsignal-protocol && npm test
cd packages/data-domains && npm test
node scripts/ci/crypto-proof-harness.mjs
bash scripts/ci/verify-signal-activation-parity.sh
bash scripts/ci/verify-signal-honesty-copy.sh
RUN_TESTS=false bash scripts/ops/signal-rollback-drill.sh
```

Expected special case:

```bash
bash scripts/ci/verify-signal-rule0.sh
```

This should still flag `.gitmodules`, `Vendor/libsignal/`, and `website/src/data/trust.generated.ts`. That is not a test failure. It is the intended owner gate for AGPL/libsignal vendoring and generated public trust copy.

---

## Non-Negotiable Guardrails

- Keep all Signal production activation flags OFF until Phase E.
- Do not bypass the remaining legal, cryptographer, store, physical-device, or rollback gates.
- Do not weaken relocation binding. Every open path must continue using caller-derived expected binding, not envelope-supplied binding, for AAD.
- Do not publish uncaveated "zero-knowledge", "server learns nothing", "Signal-quality privacy", or "searches/search without reading" copy.
- Do not land Rule-0 paths without explicit owner/legal/copy ratification.
- Every skeptical review must write a durable Markdown report to:

```bash
mkdir -p "$HOME/Desktop/Signal Audit"
date +"%Y-%m-%d-%H%M%S"
# filename format:
# ~/Desktop/Signal Audit/audit-<model-that-produced-it>-<YYYY-MM-DD>-<HHMMSS>.md
```

The audit file must include severity, `file:line`, repro/attack, verdict, fix recommendation, and exact commands run.

---

## Remaining Work, In Correct Order

### 1. External Cryptographer Review

**Status:** not done.
**Owner:** external crypto reviewer, not an implementation agent.
**Why it blocks activation:** this migration introduces a Signal/libsignal-backed at-rest and transport envelope. The implementation has internal proof, but no independent expert sign-off.

Who can do it:

- Best: a professional cryptography/security consultant or firm with protocol-review experience.
- Good: a senior security engineer outside this repo who has shipped/audited E2EE or Signal/libsignal systems.
- Acceptable for a pre-GA gate only if Alberto explicitly accepts the risk: a separate AI/model adversarial audit saved to `~/Desktop/Signal Audit/`, clearly labelled **AI audit, not independent human sign-off**.

The same implementation agent cannot honestly sign this gate. It can prepare the package and fix findings, but independence requires a separate reviewer.

Concrete options to contact: Trail of Bits, NCC Group, Cure53, Least Authority, Latacora, or an independent applied cryptographer/security engineer with E2EE review experience. The deliverable is not a chat opinion; it is a named report with signer/reviewer identity, scope, findings, and disposition.

Inputs:

- `docs/signalification/EXTERNAL_CRYPTO_REVIEW_PACKAGE.md`
- `docs/signalification/SIGNAL_ENVELOPE_V1.md`
- `docs/signalification/DOMAIN_SIGNALIFICATION_MAP.md`
- `docs/signalification/SKEPTICAL_ADVERSARIAL_REVIEW_HANDOFF.md`
- `.agent/runs/sotasignal-full-ship-20260605/evidence/adversarial-3waves.json`
- `~/Desktop/Signal Audit/audit-claude-opus-4-8-2026-06-05-023411.md`

Reviewer must attack:

- AAD grammar and cross-language byte parity.
- Swift/Android/TS relocation resistance.
- HPKE at-rest identity-key use and lack of at-rest forward secrecy.
- Transport v4 downgrade/replay/mode confusion.
- Trust root and safety-number/key-bound display.
- Metadata/search/vector residual leaks.
- Rollback and activation gates.

Acceptance:

- A signed/reviewed Markdown or PDF report exists.
- Every blocker/major finding is either fixed and reverified or explicitly accepted by Alberto as launch-risk.
- The report is copied into `~/Desktop/Signal Audit/audit-<reviewer>-<date-time>.md` or linked from that folder.

---

### 2. Legal, AGPL, MAS, and Store Sign-Off

**Status:** not done.
**Owner:** legal/store owner.
**Why it blocks activation/landing:** libsignal is AGPL-3.0-only and Rule-0 intentionally flags the vendored dependency and generated public trust copy.

Who can do it:

- Best: an attorney or OSS compliance specialist who understands AGPL obligations and Apple App Store / Mac App Store distribution constraints.
- Good: a senior release/compliance owner with written authority to accept OSS/license/store risk for OpenBurnBar.
- If Alberto self-approves: record it as **owner risk acceptance**, not "legal sign-off". That can unblock an internal/private build, but it is weaker than legal review for public release.

An implementation agent cannot provide legal advice or create a true legal sign-off. It can only prepare the artifact list, source-offer language, manifests, and risk memo for the approver.

Concrete options: company counsel, an OSS licensing attorney, an OSS compliance consultant, or the Apple/store release owner with written authority. The required artifact is a dated approval/risk-acceptance note that names the exact distribution target: direct-download macOS, MAS, iOS App Store, Android/Play, or internal-only.

Must review:

- `.gitmodules`
- `Vendor/libsignal/`
- Any generated or packaged `OpenBurnBarSignalFfi.xcframework`
- `OpenBurnBarCore/Package.swift`
- Android Gradle Signal dependencies and Maven source
- License manifests, `NOTICE`, `THIRD_PARTY*`, `LICENSES/`, source-offer obligations
- MAS distribution constraints for any AGPL-linked binary
- `website/src/data/trust.generated.ts` generated public trust copy after the honesty wording change

Acceptance:

- Legal approves the AGPL/source-offer/distribution plan in writing.
- MAS/App Store distribution plan is explicitly approved or the feature is excluded from MAS builds.
- `bash scripts/ci/verify-signal-rule0.sh` either passes against the intended landing base or its flagged paths have explicit owner approvals recorded in the release evidence.

---

### 3. Reproducible Native Packaging Proof

**Status:** local reproducible Apple FFI + host/device debug proof is now green; release/notarization/store proof still requires owner/legal sign-off.
**Owner:** native packaging/operator.
**Why it blocks device E2E and store release:** the current tree has native libsignal work, but the release-quality multi-platform packaging proof still needs to be reproduced end to end.

Apple proof now collected:

- `scripts/build-signal-ffi-xcframework.sh` completed successfully.
- `Vendor/OpenBurnBarSignalFfi.xcframework` contains `ios-arm64`, `ios-arm64_x86_64-simulator`, and `macos-arm64`.
- `swift test --package-path OpenBurnBarCore --filter SignalAtRestSealerTests` passed against the rebuilt FFI package.
- `xcodebuild ... -scheme OpenBurnBarMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' ... build` passed.
- `xcodebuild ... -scheme OpenBurnBar -destination 'platform=macOS' ... build` passed.
- `OPENBURNBAR_IOS_DESTINATION='platform=iOS,id=AFB07C15-AD18-5EFA-AD1C-CADB4F286797' ./scripts/test-openburnbar-mobile.sh` passed on a physical iPhone: 972 tests, 24 skipped, 0 failures.

Remaining release Apple proof:

- Verify Xcode project integration through `project.yml`/XcodeGen, not hand-edited `.pbxproj` drift.
- Prove notarization/direct-download packaging if Path C/macOS direct download uses this binary.
- Prove MAS build either links legally or compiles the relevant path out.

Android proof now collected:

- Focused Signal JVM tests pass.
- `:app:assembleDebug` passes.
- Debug APK installs on the connected `SM-S921U` device.
- `:app:connectedDebugAndroidTest -Pandroid.testInstrumentationRunnerArguments.class=com.openburnbar.data.cloud.CloudVaultCryptoSignalInstrumentedTest` passes on physical Android: the committed Node KAT opens on-device, relocation fails closed, the high-level Signal envelope roundtrips, and expected-binding mismatch fails closed.
- Signal Maven source proof is collected: `org.signal:libsignal-android:0.94.4` resolves from `https://build-artifacts.signal.org/libraries/maven/` and returns 404 from Maven Central.

Remaining Android release proof:

- Confirm Kotlin metadata warnings are either harmless and documented or fixed.

Suggested commands:

```bash
bash scripts/build-signal-ffi-xcframework.sh
xcodegen generate -p OpenBurnBar.xcodeproj
swift test --package-path OpenBurnBarCore --filter SignalEnvelopeAADTests
swift test --package-path OpenBurnBarCore --filter SignalAtRestSealerTests
xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath build/DerivedData-signal-mobile build
cd android && ANDROID_HOME=$HOME/Library/Android/sdk ./gradlew :app:testDebugUnitTest :app:assembleDebug --no-daemon
```

Acceptance:

- Packaging steps are scripted, reproducible, and documented.
- Build logs are saved under `.agent/runs/sotasignal-full-ship-20260605/evidence/` or a new run folder.
- No manual dylib/framework artifact is treated as final unless the script can recreate it.

---

### 4. Physical-Device E2E Matrix

**Status:** local physical Signal device proof is now green for the implemented flag-OFF code on reachable iPhone/iPad/Android surfaces; live production-domain E2E is still pending because producers remain flag-OFF.
**Owner:** device operator with attached iPhone/iPad/Android/Mac.
**Why it blocks activation:** simulator/unit proof is not enough for keychain, libsignal native bindings, app lifecycle, trust UI, and cross-device ciphertext interoperability.

Proof now collected:

- Physical iPhone: `./scripts/test-openburnbar-mobile.sh` against `AFB07C15-AD18-5EFA-AD1C-CADB4F286797` passed.
- Physical iPhone focused mobile assistant chat Signal path-binding: `MobileChatHistoryStoreTests/testDecodeThreadOpensPathBoundSignalEnvelopeAndRejectsRelocation` passed on `AFB07C15-AD18-5EFA-AD1C-CADB4F286797`.
- Physical iPhone focused CLI mission Signal path-binding: `CLIAgentMissionDispatcherSealTests/test_missionSnapshotOpensPathBoundSignalEnvelopeAndRejectsRelocation` passed on `AFB07C15-AD18-5EFA-AD1C-CADB4F286797`.
- Physical Android: `CloudVaultCryptoSignalInstrumentedTest` against `R3CXB0CNS0J` / `SM-S921U` passed.
- Physical iPad final rerun: `PensieveMemorySearchSignalTests` passed **3/3** on `00008132-001158191E9A401C`, and `MobileChatHistoryStoreTests/testDecodeThreadOpensPathBoundSignalEnvelopeAndRejectsRelocation` passed **1/1** on the same wired iPad. Logs: `.agent/runs/sotasignal-full-ship-20260605/evidence/device-physical-final/`.

Remaining live matrix after producer wiring:

- iPhone physical device.
- iPad physical device once CoreDevice reports it `available`.
- Android physical device.
- macOS app.
- Mac agent/daemon path.
- Python/agent route if it participates in Signal transport or CloudVault reads.

Minimum flows:

- Seal on iPhone, open on Mac.
- Seal on Mac, open on iPhone.
- Seal on Android, open on Mac/iPhone.
- At-rest `pensieve` domain write/read.
- Mobile assistant chat Signal at-rest write/read.
- CLI mission request Signal at-rest write/read.
- Trust approval safety-code compare.
- Device revocation prevents future decrypts.
- Legacy AES/old envelopes still dual-read.
- Relocated ciphertext fails to open on every platform.

Suggested commands:

```bash
OPENBURNBAR_IOS_DESTINATION='platform=iOS,id=<iphone-udid>' ./scripts/test-openburnbar-mobile.sh
./scripts/cross-platform/run-ios 'iPhone 17 Pro Max'
cd android && ANDROID_HOME=$HOME/Library/Android/sdk ./gradlew :app:installDebug
adb devices
make build
make install
```

Acceptance:

- Device logs/screenshots are saved.
- Each flow records source device, destination device, domain, envelope version, expected binding, and pass/fail.
- Failures are fixed or explicitly deferred before Phase E.

---

### 5. Production Producer Wiring and Admin Validator Wiring

**Status:** partially closed while flag-OFF. The first server/Admin seam is now wired and tested for pensieve: `commitKnowledgeBatch` accepts an optional path-bound `signalEnvelope`, validates it with `validateSignalAtRestEnvelopeForWrite`, stores only the sanitized envelope, and `searchKnowledge` returns it additively alongside legacy sealed fields. Evidence: `.agent/runs/sotasignal-full-ship-20260605/evidence/producer-wiring-recon-20260605.md`.
**Owner:** feature/domain implementer.
**Why it still blocks activation:** validators and sealers exist, but app/daemon producers are not yet writing real Signal envelopes across every target domain, pensieve clients do not yet open returned Signal envelopes, and Android direct client writers are still legacy-only.

Work required:

- Finish the first ramp domain (`pensieve`): app/daemon producer must add optional `signalEnvelope` bound to `cloud_search_knowledge/{vectorId}/sealedCiphertext`; client reader must prefer it when present and fall back to legacy `ciphertext`.
- Preserve legacy opener/dual-read until Phase-E activation is fully rolled out.
- Ensure every remaining Admin SDK/callable write path that persists `signalEnvelope` calls:

```ts
assertSignalAtRestEnvelopeForWrite(...)
```

and persists the sanitized returned envelope, not the raw request object.

- Ensure direct client writes either:
  - are forbidden from writing `signalEnvelope`, or
  - route through a callable that performs deep wrap validation.
- Add telemetry for seal/open success, fallback, legacy open, relocation reject, malformed envelope reject, and admin validator rejects.
- Add migration/readback dashboards before activating writes.

High-risk files to audit:

- `functions/src/signalAtRestWrite.ts`
- `firestore.rules`
- `functions/scripts/test-firestore-rules.mjs`
- `OpenBurnBarMobile/Services/MobileCloudVaultSignalPayloads.swift`
- `OpenBurnBarMobile/Services/MobileChatHistoryStore.swift`
- `OpenBurnBarMobile/Services/CLIAgentMissionDispatcher.swift`
- `android/app/src/main/java/com/openburnbar/data/cloud/CloudVaultCrypto.kt`
- `AgentLens/Services/CloudVaultKeyAccess.swift`
- `packages/data-domains/registry.json`

Acceptance:

- First producer is wired behind flag/capability and is dark by default.
- Admin validator is called at the first real admin/callable write site.
- Rules, unit tests, emulator tests, and device E2E all prove relocation fails.
- Telemetry proves no unexpected plaintext or legacy-only regression.

---

### 6. L40: `sourceSlugToken` to Canonical `sourceManifestId`

**Status:** done in the current working tree (2026-06-05).
**Owner:** backend/data migration owner.
**Evidence:** `.agent/runs/sotasignal-full-ship-20260605/evidence/l40-source-manifest-id.md`.
**What changed:** Stream 7 HMAC `sourceSlugToken` closed the cleartext slug write path; L40 now promotes that opaque routing value to canonical `sourceManifestId` while preserving lazy dual-read for existing rows.

Scope:

- `connectKnowledgeRepo` writes canonical `sourceManifestId`, deletes transitional `sourceSlugToken`, and deletes legacy cleartext `sourceSlug` on reconnect.
- `listKnowledgeRepos` reads `sourceManifestId || sourceSlugToken || sourceSlug` for manifest resolution, but only returns opaque `sourceManifestId` plus a response-only `sourceSlugToken` alias; it never echoes legacy cleartext `sourceSlug`.
- Webhook routing and manual resync use the same lazy dual-read order.
- `commitKnowledgeBatch`, `configureKnowledgeSource`, and `deleteKnowledgeSource` accept legacy request `sourceSlug` as an alias, but persist/return canonical `sourceManifestId`.
- `dataExport` treats `sourceManifestId` as an opaque export-safe column.
- Focused unit tests cover new writes, reconnect upgrade/delete, manifest persistence, and export.

Acceptance:

- No cleartext slug write path.
- Existing repos remain readable through lazy dual-read.
- Transitional `sourceSlugToken` rows are upgraded on reconnect without a server backfill.
- New manifests store `sourceManifestId` and not `sourceSlug`.
- No orphaned manifests.
- Backfill is idempotent and reversible.
- Emulator tests cover legacy dual-read and new canonical ID.

---

### 7. Broader L41: Signal Identity, Prekey, Session Directory, and Rotation

**Status:** server/rules/design contract is now complete; producer/runtime wiring remains.
**Owner:** identity/key-storage owner for client producers and re-wrap jobs.
**Design:** [`docs/signalification/L41_SIGNAL_PREKEY_SESSION_DIRECTORY.md`](L41_SIGNAL_PREKEY_SESSION_DIRECTORY.md).
**Rules evidence:** `cd functions && npm run test:firestore-rules` → 50/50, including
`L41 Signal prekey/session directory is path-bound, public-only, and rotation-aware`.

Done in the server/rules lane:

- `signal_identity_public_keys` now supports bounded identity rotation via explicit `keyVersionLabel` for versions 1 through 10, still bound to `escrow_devices/{deviceId}.keyVersion`.
- Added nested directories under each Signal identity key:
  - `signed_prekeys/{signedPreKeyId}`
  - `one_time_prekeys/{oneTimePreKeyId}`
  - `kyber_prekeys/{kyberPreKeyId}`
  - `sessions/{sessionId}`
  - `rotation_events/{rotationId}`
- Rules reject private keys and serialized Signal session/ratchet state.
- Signed prekeys, one-time prekeys, Kyber prekeys, sessions, and rotation events have create/update/delete constraints covered by the emulator.
- Session directory docs are metadata-only with `stateStorage == "device-local-only"`.
- Rotation events are append-only and require `fromKeyVersion < toKeyVersion`.

Remaining before production activation:

- Add client Keychain/Keystore producers that publish only public identity/prekey material into the rules-backed paths.
- Wire prekey claiming/refresh to the real Signal session-establishment path.
- Wire revocation to exclude revoked identities from future wraps and trigger re-wrap of previously wrapped data.
- Prove key rotation does not break legacy dual-read and does not orphan still-needed wrapped data.
- Keep TOFU/manual trust limits in the threat model and external-review package.

---

### 8. Phase-E Activation and Ring Rollout

**Status:** not started.
**Owner:** release/ops.
**Prerequisites:** external crypto review, legal sign-off, packaging proof, physical-device E2E, producer wiring, telemetry, rollback proof.

Activation levers to audit before changing:

- `functions/src/hermesGateway.ts`
  - `HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS`
  - production negotiation for `supportsSignalEnvelope`
- `functions/src/callables/computerUseSecurity.ts`
  - escrow fingerprint enforcement flag
- `packages/data-domains/registry.json`
  - per-domain `sealingScheme`
- Remote Config/env kill switches once actually wired

Rollout sequence:

1. Re-run all proof gates on the exact activation candidate.
2. Dry-run rollback drill.
3. Enable one internal canary account/domain.
4. Verify dual-read, new-write, legacy-read, revocation, and telemetry.
5. Expand ring-by-ring.
6. Run live timed rollback drill and record elapsed time.
7. Only then consider broader release.

Acceptance:

- Ring status is recorded with exact dates and commit SHAs.
- Rollback works in the target SLO, not just locally.
- Sentry/ops dashboards have no unexpected errors.
- Owner signs off on every ring advance.

---

## Phase 2.5 — Cross-device + bidirectional E2EE correctness (task #17)

**Status:** closed for the agent-verifiable scope (test-first KATs + the minimal code to keep
them permanent). Flag-OFF preserved; no envelope format-version bump
(`SIGNAL_ENVELOPE_FORMAT_VERSION` = 1, `SIGNAL_RELAY_KEY_VERSION` = 4 unchanged). This phase proves
the correctness of the cross-device/bidirectional *plumbing*; production activation is still gated by
sections 1, 4, 5, and 8 below.

Closed in this phase (committed KATs/fixtures, both directions where applicable):

- [x] **G1 — reverse-direction cross-language interop fixture.** `android-alice-to-swift-bob.json`
  generated by the Android `AndroidSignalInteropFixtureGen`, committed byte-identical in three
  locations, opened cross-language by the Swift `OBBSignalInteropKatTests` (Swift-Bob decrypts the
  Android-libsignal-produced PreKey + chain-advanced message) and guarded by
  `AndroidSignalReverseInteropKatTest`. Complements the pre-existing `swift-alice-to-android-bob.json`.
- [x] **G2 — bidirectional transport-over-iroh ratchet KAT.** Already closed on the base commit:
  `OBBSignalSessionOverIrohTests.testLoopbackSignalSessionRoundTrip` and the Android twin
  `AndroidSignalSessionOverIrohTest.loopbackSignalSessionRoundTrip` already assert the Alice→Bob
  prekey leg AND the Bob→Alice **whisper** (DH-ratchet) reply in both directions. No new code added.
- [x] **G3 — cross-device at-rest fan-out + revoke fail-closed matrix.** One envelope sealed for
  `[deviceA, deviceB, escrow, recovery]` opens on every listed device; a revoked device's wrap is
  absent and fails closed; a foreign-uid device fails closed. Swift `SignalAtRestSealerTests` +
  Android `CloudVaultSignalFanOutTest`.
- [x] **G4 — rotation/rewrap cross-device handoff KAT.** After rotation the new key opens, the old
  wrap is gone (old key fails closed via the vaultKeyID guard), a stale pre-rotation ciphertext fails
  closed, and the Signal identity transition v1→v2 is well-formed. Swift
  `CloudVaultRotationHandoffKATTests` + Android `AndroidCloudVaultRotationHandoffKatTest`. Test-only;
  no production change required (the rewrap core was already correct).
- [x] **G5 — directory bidirectional claim invariants.** Claim consumes a one-time prekey (never
  re-issued; exhausted → undefined), the claim side rejects every private/serialized-session
  encoding, and the replenish gate trips with strict less-than at each floor. TS
  `signalPrekeyDirectory.test.ts`.
- [x] **G6 — transport-mode binding/AAD byte-parity vector.** A dedicated transport-binding vector
  (`transport-binding-aad-vectors.json`, byte-mirrored into the Swift test fixtures), an additive
  `[A2]` section + Section D transport sha-pin in `crypto-proof-harness.mjs`, and Swift + Android
  consumers (`SignalEnvelopeTransportAADParityTests`, `CloudVaultTransportBindingParityTest`). The
  at-rest vectors / harness sections A/B/C/D and their pins are untouched.
- [x] **Permanence gate.** New CI workflow `.github/workflows/signal-cross-device-kats.yml` runs the
  Node/Linux legs (`scripts/ci/verify-signal-cross-device-kats.sh`: reverse-fixture structure +
  byte-identity, the crypto-proof harness incl. the transport section, and the contract directory
  cases), also runnable via `make signal-cross-device-kats`. The native cross-device OPEN runs on the
  macOS/Android PR harness (the documented platform-suite convention), not silently skipped.

**AGPL coordination handoff — make the gate merge-blocking (one owner action).** The permanence
gate is wired as a NEW workflow file because `.github/workflows/fast-feedback.yml` is on the AGPL
Rule-0 avoid-list (`SWARM_RUNBOOK.md`: "wire a NEW workflow file instead"); no edit to that file or
its `agpl-compliance` license job was made. **Known gap:** a standalone workflow runs on every PR
but only *blocks merge* if branch protection requires it — so today this gate is advisory, not
merge-blocking. To close that, the repo/AGPL owner does ONE of:
  1. **(preferred, no avoid-list edit)** Add the status check **`Signal cross-device KATs / signal-cross-device-kats`**
     to the `main` branch-protection "Require status checks to pass" list (GitHub → Settings → Branches,
     or `gh api repos/:owner/:repo/branches/main/protection` with the check name). Turnkey; no file change.
  2. **(if the AGPL owner edits `fast-feedback.yml`)** append the `signal-cross-device-kats` job to its
     `jobs:` map and add `- signal-cross-device-kats` to the `fast-feedback-gate` `needs:` list (the
     aggregator's `toJSON(needs)` logic then enforces it automatically). Must NOT touch the
     `agpl-compliance` job; additive-only diff.
Until one of those lands, the macOS/Android platform PR harness + the advisory workflow are the
enforcement surface.

**Tracked follow-up tests (out-of-phase, named — not silently dropped):**
- **Claim-consume integration test (§7/L41).** The single-use prekey-claim invariant is covered at
  the pure level by `selectPrekeyToClaim` (lowest-available pick) + `buildPrekeyClaimStamp`
  (`status: "claimed"` mutation), both unit-tested against production code in
  `signalPrekeyDirectory.test.ts`. The full transactional consume — the `claimSignalPrekeyBundle`
  `runTransaction` with the `status == "available"` query + `tx.update` — needs a Functions-emulator
  integration test (firebase-functions-test, not yet a dep) to prove a claimed prekey is never
  re-issued end-to-end. Out of the plan's pure-unit G5 scope by design.
- **Rotation rewrap worker cross-device race.** The worker's already-rotated short-circuit +
  old-storage-blob delete are not atomic across two devices; a race could leave an orphaned old-key
  blob or abort a partially-rewritten scan. The G4 core KAT pins the per-document crypto invariant
  the worker depends on; the worker-level race needs a live-Firestore integration test under §5.

Explicitly **out of Phase 2.5** (remains as handoff, not silently dropped): vendoring new native
libsignal binaries (AGPL owner); turning production Signal producers flag-ON (§5/§8); the
physical-device E2E matrix (§4); external cryptographer sign-off (§1).

---

## Final Remaining Definition Of Done

The Signal migration can be called production-ready only when all are true:

- External cryptographer review completed and blockers closed.
- Legal/AGPL/MAS/store sign-off completed.
- Reproducible native packaging proof completed.
- Physical-device E2E matrix completed.
- Production producers wired and admin validator called at real write sites.
- L40 canonical source identity complete.
- Broader L41 key/prekey/session directory and rotation complete or explicitly scoped out with owner sign-off.
- Phase-E activation performed through rings with live rollback proof.
- `~/Desktop/Signal Audit/` contains final audit reports for each major review/activation gate.

Until then, the honest status is:

**Implementation complete for the current agent-verifiable scope; production activation still blocked by external, legal, device, packaging, producer, identity, and ops gates.**
