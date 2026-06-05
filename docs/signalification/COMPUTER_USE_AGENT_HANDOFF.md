# Computer-Use Agent Handoff — Finish the Signal Migration end-to-end (SOTA)

> **Audience:** an autonomous computer-use agent on Alberto's Mac that can run shell, build Xcode/Gradle, and deploy to the **attached physical devices**.
> **Repo:** `/Users/albertonunez/Documents/Windsurf/BurnBar` · **Base:** `main @ 794b2246a` (everything below is committed here).
> **Mission:** take the Signal migration from *server/schema/crypto-proven, flag-OFF* to *real client ciphertext on all platforms, on-device E2E verified, then activated* — **no stubs, no workarounds**.

---

## 0. Current state (what is already TRUE on `main`)

- **Server/schema/validator/type layers landed flag-OFF + adversarially audited (43-agent: SAFE, 0 land-blockers):** P0 `bindingToAAD` canonicalizer, Stream 3 gateway v4 `signalEnvelope` shape, Stream 5 `CloudVaultSignalEnvelope` type + registry `sealingScheme`, Stream 6 enablement code (key-bound verifier + server enforcement in shadow mode + P-256 on-curve checks).
- **Real libsignal 0.94.4 crypto PROVEN in Node + Swift + Kotlin**, with a **cross-language KAT** (Node-sealed HPKE opens byte-correct in Swift AND Kotlin via the identical `bindingToAAD`; tamper fails closed). Evidence + working openers in `.agent/runs/signalification-phases-3to8-20260604/evidence/`.
- **Everything is flag-OFF** — all production writes are still AES-256-GCM. Nothing emits a v4 envelope or real Signal ciphertext yet.

**Your job is the productionization marked `[incomplete]` in `.agent/runs/signalification-phases-3to8-20260604/GOAL.md`.**

---

## 1. Invariants — DO NOT VIOLATE

1. **Stay flag-OFF until Phase E.** Do not flip any activation flag until on-device E2E (Phase D) passes AND external review (Phase F) is requested. The three flags are in §Phase E.
2. **Never weaken fail-closed / default-deny / strict-equality.** Every sealer must fail closed on missing/invalid keys (mirror the existing `pinnedSenderKey == nil → refuse`).
3. **`bindingToAAD` is the single source of AEAD bytes.** Both `info` and `associatedData` derive from it. Canonical form (NFC, fail-closed on `|`/CR/LF):
   `aad = "OpenBurnBar-Signal-AAD-v1|" + [mode, scope, uid, clientId, collection, docId, field, slotId, formatVersion].join("|")` (absent optionals = empty segments)
   `info = "OpenBurnBar-Signal-AtRest-v1|" + aad`
   TS: `packages/signal-envelope-contracts/src/index.ts:bindingToAAD`. Swift: `OpenBurnBarCore/.../SignalEnvelopeAAD.swift:signalEnvelopeBindingToAAD`. **Add the Kotlin mirror** identically (NFC via `java.text.Normalizer.normalize(..., NFC)`).
4. **Keep legacy openers.** Old AES-GCM/HPKE/ratchet envelopes must still open (lazy dual-read). Signal is a *new* v4 family.
5. **Landing to `main` is protected** (`enforce_admins`). Use the surgical toggle (you have `gh` admin):
   ```bash
   REPO=Imagine-That-Ai/BurnBar
   gh api -X DELETE repos/$REPO/branches/main/protection/enforce_admins   # bypass
   git push origin HEAD:main                                              # FF only
   gh api -X POST  repos/$REPO/branches/main/protection/enforce_admins    # ALWAYS restore
   gh api repos/$REPO/branches/main/protection | python3 -c "import sys,json;d=json.load(sys.stdin);print('enforce_admins',d['enforce_admins']['enabled'])"
   ```
   Prefer a feature branch (`signal/phase3`) + the same FF land. Always re-enable protection even if the push fails.
6. **Don't over-claim.** Do NOT add "Signal-quality privacy" copy. The cosine-vector graph (`PensieveVectorCloak`), deterministic search trapdoors, and routing metadata still leak — see `docs/signalification/00_ORCHESTRATION.md` over-claim guard.

---

## 2. Toolchain (already installed + proven in-agent)

- Xcode 26.5 / Swift 6.3.2 · `cargo` 1.94 · `protoc` (libprotoc 35) — `brew install protobuf` if missing (libsignal Swift `build_ffi` needs it).
- Android SDK at `$HOME/Library/Android/sdk` (platform-tools, build-tools;35.0.0, platforms;android-35). `adb` on PATH. `gradle` via brew. JDK 21 at `/Users/albertonunez/.homebrew/Cellar/openjdk@21/21.0.10/libexec/openjdk.jdk/Contents/Home`.
- **Attached devices:** iPhone 17 Pro Max UDID `00008150-00180C661EF0401C`; Android `R3CXB0CNS0J` (`adb devices`); also iPad `00008132-001158191E9A401C`. Simulators "iPhone 17 Pro Max" booted.
- libsignal pin: **v0.94.4**, commit `03c449017b57eccbda715b8b018dce5dff603ac6` (`third_party/libsignal/manifest.json`).

---

## 3. PROVEN build recipes (these exact recipes ran green in-agent — reuse them)

### Swift (libsignal SwiftPM)
The package lives in libsignal's **`swift/` subdirectory**, so a bare `.package(url:)` fails. Vendor it and reference by **local path**:
```bash
git clone --depth 1 --branch v0.94.4 https://github.com/signalapp/libsignal Vendor/libsignal   # or git submodule
( cd Vendor/libsignal/swift && ./build_ffi.sh --release )                                       # builds signalFfi via cargo (needs protoc)
# Consumer must link the FFI static lib:  -L <repo>/Vendor/libsignal/target/release   (product name: LibSignalClient)
```
Verified Swift API (from the working proof `evidence/swift-kat-opener.swift` + the session proof):
- `IdentityKeyPair.generate()`; `kp.publicKey` / `kp.privateKey`; `try PrivateKey(bytesArray)`.
- At-rest: `try pub.seal(msg, info: [UInt8], associatedData: [UInt8])` / `try priv.open(ct, info:, associatedData:)`.
- Session: `try processPreKeyBundle(bundle, for: addr, ourAddress: localAddr, sessionStore:, identityStore:, context: NullContext())`; `try signalEncrypt(message:, for:, localAddress:, sessionStore:, identityStore:, context:)`; `try signalDecryptPreKey(message:, from:, localAddress:, sessionStore:, identityStore:, preKeyStore:, signedPreKeyStore:, kyberPreKeyStore:, context:)`. PQXDH Kyber prekey is **mandatory** in `PreKeyBundle`.
- Safety number: `NumericFingerprintGenerator(iterations: 1024).create(version: 2, localIdentifier:, localKey: PublicKey, remoteIdentifier:, remoteKey: PublicKey).displayable.formatted`.
- Stores: `InMemorySignalProtocolStore(identity:, registrationId:)` (reference impl); for production implement the libsignal store protocols backed by Keychain + Firestore.

### Kotlin/Android
```kotlin
// settings.gradle.kts repositories:  maven { url = uri("https://build-artifacts.signal.org/libraries/maven/") }   // 0.94.4 is HERE, not Maven Central (which stops at 0.86.5)
// app/build.gradle.kts:  implementation("org.signal:libsignal-android:0.94.4")   // APP uses libsignal-android (AAR + .so); JVM tests can use org.signal:libsignal-client
// Kotlin plugin MUST be 2.2.x (libsignal 0.94.4 metadata is Kotlin 2.2). Bump android Kotlin plugin (currently ~2.1.0) and re-verify the app build.
```
Verified Kotlin API (`evidence/kotlin-kat-opener.kt`): `IdentityKeyPair.generate()`; `kp.publicKey.publicKey` is `ECPublicKey` with `.seal(pt, info, aad)`; `ECPrivateKey(bytes)` + `.open(ct, info, aad)`; on JVM/desktop `org.signal:libsignal-client` bundles the host native lib.

### Node — already real (`packages/libsignal-protocol`, 7/7). KAT generator pattern in `evidence/` history.

### Re-run the cross-language KAT to confirm parity any time
The committed vector `evidence/SignalEnvelopeV1Vector.json` + `swift-kat-opener.swift` + `kotlin-kat-opener.kt` open a Node-sealed ciphertext. Use them as the regression oracle after every change.

---

## Phase A — Vendor libsignal into the app build graphs

### A1. iOS / Mac (shared via OpenBurnBarCore — lands once)
1. Vendor: `Vendor/libsignal` (submodule pinned to `v0.94.4`) + run `build_ffi.sh --release` (recipe §3).
2. `OpenBurnBarCore/Package.swift`:
   - add dependency `~line 87`: `.package(name: "LibSignalClient", path: "../Vendor/libsignal/swift")`.
   - add product `~line 51`: `.library(name: "OpenBurnBarSignalCore", targets: ["OpenBurnBarSignalCore"])`.
   - add target `~line 156`: `.target(name: "OpenBurnBarSignalCore", dependencies: ["OpenBurnBarCore", .product(name: "LibSignalClient", package: "LibSignalClient")], path: "Sources/OpenBurnBarSignalCore", linkerSettings: [.unsafeFlags(["-L../Vendor/libsignal/target/release"])])`.
3. `project.yml` (XcodeGen — **never edit `.pbxproj`**):
   - `packages:` block `~line 50`: add `LibSignalClient: { path: Vendor/libsignal/swift }` (mirror the GRDB entry).
   - `OpenBurnBarMobile` target deps `~line 600`, and `OpenBurnBarMobileTests` `~line 627`: add `- package: LibSignalClient` / `product: LibSignalClient`. (Widget/Keyboard only if they seal.)
   - Regenerate: `xcodegen generate -p OpenBurnBar.xcodeproj`.
4. Verify build: `xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobile -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -clonedSourcePackagesDirPath .spm-cache-new -derivedDataPath build/DerivedData build` and `swift build --package-path OpenBurnBarCore`.

### A2. Android
1. `android/settings.gradle.kts` `~line 11-14`: add the Signal maven repo.
2. `android/app/build.gradle.kts` `~after line 328`: add `org.signal:libsignal-android:0.94.4`.
3. `android/build.gradle.kts` `~line 3`: bump Kotlin plugin to **2.2.x**; re-verify the app compiles (this is the one real risk — fix any Kotlin-2.2 migration warnings).
4. Verify: `cd android && ANDROID_HOME=$HOME/Library/Android/sdk ./gradlew :app:assembleDebug`.

**Commit Phase A** (build-graph only, still flag-OFF). Update `third_party/libsignal/runtime-readiness.json` (`swift_round_trips`, `android_round_trips` → from `pending`).

---

## Phase B — Real sealers (consume `bindingToAAD`, fail-closed)

### B1. Swift `OpenBurnBarSignalCore` (new target from A1)
Implement, mirroring `packages/libsignal-protocol/src/index.ts`:
- `atRestSeal(plaintext, recipientIdentityPublicKey, binding) -> CloudVaultSignalEnvelope` using `PublicKey.seal(pt, info: utf8(AT_REST_INFO_PREFIX+aad), associatedData: utf8(aad))` where `aad = signalEnvelopeBindingToAAD(binding.aadBinding)` (bridge already at `CloudVaultCrypto.swift:CloudVaultSignalBinding.aadBinding`).
- `atRestOpen(envelope, localIdentityPrivateKey) -> Data`.
- transport seal/open via `signalEncrypt`/`signalDecryptPreKey` + a Keychain/Firestore-backed store impl.
- safety number via `NumericFingerprintGenerator`.
- **Tests:** add `OpenBurnBarSignalCoreTests` that (a) round-trips, (b) opens the committed `SignalEnvelopeV1Vector.json` (Node→Swift), (c) tamper fails closed.

### B2. Kotlin
- New `android/.../data/cloud/CloudVaultCryptoSupport.kt`: `decodeSignalPublicKey/encodeSignalPublicKey` (`org.signal.libsignal.protocol.ecc.ECPublicKey/ECPrivateKey`), `bindingToAAD` (NFC, byte-identical to TS/Swift), `atRestSeal/atRestOpen`.
- Extend `android/.../data/cloud/CloudVaultCrypto.kt` `~line 27-100` with `CloudVaultSignalEnvelope`.
- **Test:** `BudgetRuleSealedFieldsTest.kt` add Signal round-trip + open the same KAT vector.

### B3. Node — already real; expose the seal path for the server/relay if needed (currently inert in `libsignal-protocol`).

**Gate:** the cross-language KAT must still pass in all three. Commit Phase B (still flag-OFF; sealers exist but unused).

---

## Phase C — Wire real ciphertext through client paths (still flag-OFF, behind capability)

### iOS (`OpenBurnBarMobile`)
- `Services/FunctionsRepository.swift`:
  - `sealGatewayEventPayload(...)` `~2366-2488` (entry `~2349`): when peer advertises `supportsSignalEnvelope` and `canSealToAgent` `~144`, produce a **transport** `signalEnvelope` via B1; keep the `pinnedSenderKey == nil → refuse` fail-closed at `~2415-2420`. **Audit activation-gate item:** also bind routing identity — derive the libsignal `ProtocolAddress` name deterministically from the binding (`"\(uid):\(scope):\(clientId)"`) so `clientId/slotId` are authenticated, not recognizer-only.
  - `decodedText(...)` `~938-1095`: add a v4 open branch using the pinned Signal identity; refuse unsealed when pinned (mirror existing downgrade gate).
- CloudVault at-rest: `Services/MobileCloudVaultKeyAccess.swift:publishCloudVaultKey` `~197-283` and `CloudVaultCrypto.swift:sealPayload/openPayload` `~512-575` — add the `CloudVaultSignalEnvelope` produce/consume path (B1) selected by registry `sealingScheme`, AES-GCM remains the legacy opener.
- **Stream 6 UI (audit MAJOR — the one real correctness gap):** wire the key-bound verifier that is built+tested but unused:
  1. add `publicKeyData: String?` to `MacTrustedDevice` (`DevicesAndSyncSettingsView.swift` `~666-691`) and `DeviceRecord` (`CloudGateways.swift` `~81-109`), populate from `escrow_public_keys/{deviceId}_{keyVersion}.publicKeyData`.
  2. change `safetyCode` computeds to `EscrowDeviceSafetyCode.format(publicKeyData:)` (key-bound), not `format(fingerprint:)` (server string).
  3. gate the Approve button in `DeviceTrustSafetyCompareSheet` (`~418-480`, iPad `~77-84`) on `EscrowDeviceSafetyCode.isFingerprint(fingerprint, boundTo: publicKeyData) == true` (`~128-138`).

### Android (`FirestoreRepository.kt`)
- `BudgetRule.toMap()` `~551-599` + `toBudgetRule()` `~601-631`: add Signal seal/open alongside `CloudVaultCrypto.sealText`/`openOrLegacy`, behind the same flag/scheme; legacy fallback preserved. Init libsignal in `BurnBarApplication.onCreate` `~121-151`. Follow the same pattern for `RollbackService.kt`, `AgentSubscriptionTopicStore.kt`.

### Mac (`AgentLens`) — sealers funnel through the shared `OpenBurnBarCore.CloudVaultCrypto`, so B1 covers most. Verify call sites: `CloudSync/ConversationCloudVaultPayload.swift:seal` `~99-116`, `UsageSyncService.encodeUsage`, `SessionLogSyncService`, `CloudVaultKeyAccess.swift:keyForWriting` `~97-273`; realtime `HermesRealtimeRelayHostClient.sendChunk` `~500-529` + `IrohRelay/IrohRelayRequestHandler.sendChunk` `~961-1003`.

**Gate:** functions + all client builds green; KAT green; capability still defaults false. Commit Phase C.

---

## Phase D — On-device E2E (real hardware)

1. **iPhone:** `OPENBURNBAR_IOS_DESTINATION='platform=iOS,id=00008150-00180C661EF0401C' ./scripts/test-openburnbar-mobile.sh` (run the new `OpenBurnBarSignalCore`/Mobile Signal tests on device), and `./scripts/cross-platform/run-ios 'iPhone 17 Pro Max'` for an interactive build+install. Drive the trust + chat flow with computer-use control; confirm a real Signal-sealed message round-trips device↔agent and the safety-code compare gates approval.
2. **Android:** `cd android && ANDROID_HOME=$HOME/Library/Android/sdk ./gradlew :app:installDebug` → `adb -s R3CXB0CNS0J shell am start ...`; run instrumented Signal round-trip; drive the UI.
3. **Mac:** `make build && make install`; verify CloudVault Signal at-rest read/write across the Mac↔phone pair.
4. **Cross-device interop:** seal on iPhone, open on Mac/Android (and vice versa) for a domain (start with `pensieve` at-rest). Capture logs/screenshots into `.agent/runs/signalification-phases-3to8-20260604/evidence/on-device/`.

**Gate:** all three devices demonstrate real Signal seal/open end-to-end + revocation stops future decrypts. Record in the ledger `progressEvents`.

---

## Phase E — Activation (ONLY after Phase D green + Phase F requested)

Exact one-line flips (verified locations):
- `functions/src/hermesGateway.ts:130` — `HERMES_GATEWAY_PRODUCTION_SIGNAL_ENVELOPE_VERSIONS = new Set<number>()` → `new Set([4])`.
- `functions/src/hermesGateway.ts ~1046-1058` — allow `supportsSignalEnvelope: true` negotiation (remove the `PRODUCTION.size===0` rejection).
- `functions/src/callables/computerUseSecurity.ts:100` — `ESCROW_DEVICE_FINGERPRINT_ENFORCEMENT_ENABLED = false` → `true` (Stream 6 enforcement; UI key-binding from Phase C must be live first).
- `OpenBurnBarMobile/.../EscrowDeviceSafetyCode.swift ~202` + iPad/Mac — flip `EscrowDeviceTrustSafetyCheckFlag.defaultEnabled` true.
- `packages/data-domains/registry.json:92` — `sealingScheme: "cloudvault-aesgcm-v2"` → `"signal-hpke-identity-seal-v1"` (per migrated domain; re-run `node packages/data-domains/codegen.mjs` and confirm `trust.generated.ts` change is intentional + driftcheck passes).

Ramp domain-by-domain (`pensieve` → `session_logs` → `conversations_chat`), watching Sentry/readback. Deploy via the project's pipeline (`deploy-production.yml` functions; do not bypass CI for prod).

---

## Phase F — Proof harness + external crypto review

1. Promote `evidence/SignalEnvelopeV1Vector.json` + openers into a committed CI harness `scripts/ci/crypto-proof-harness.mjs` that, on a fresh clone, runs Node+Swift+Kotlin openers against the vector and `verify-libsignal-pin.sh` (asserts v0.94.4 + `SIGNAL_RELAY_KEY_VERSION=4` + the AAD prefix across all three languages). Wire into `.github/workflows/fast-feedback.yml` (the existing `libsignal-bridge` job `~126-143` is the seam).
2. Generate the external-reviewer package: threat model (incl. the residual cosine-vector/search-index leaks from the over-claim guard), the envelope spec `SIGNAL_ENVELOPE_V1.md`, the KAT + cross-language openers, the no-FS-at-rest + revocation-re-wrap status. Request human crypto sign-off before GA copy.

---

## Verification gates (run after every phase)
```bash
# crypto + contracts
( cd packages/signal-envelope-contracts && npm test )      # 11/11
( cd packages/libsignal-protocol && npm test )             # 7/7
# functions
( cd functions && npm run build && npx vitest run )        # incl hermesGatewaySignalEnvelope + escrowDeviceTrustFingerprint
( cd functions && npm run test:hermes-gateway )
# data-domains (registry + non-websited drift)
( cd packages/data-domains && npm test )
# swift + android
( cd OpenBurnBarCore && swift build && swift test )
( cd android && ANDROID_HOME=$HOME/Library/Android/sdk ./gradlew :app:testDebugUnitTest )
# cross-language KAT regression (the oracle)
#   re-derive bindingToAAD for the vector binding; open the ciphertext in Swift + Kotlin; assert plaintext + tamper-fails-closed
```

## Remaining audit activation-gate items to honor (from `evidence/adversarial-audit-synthesis.md`)
- Transport `clientId/slotId` must be woven into the session AEAD (derive `ProtocolAddress` name from the binding) — Phase C iOS.
- Stream 6 UI key-bound display + server enforcement parity — Phase C + E.
- (Already landed: NFC normalization, P-256 on-curve checks, spec reconcile.)

## Pointers
- Plan: `docs/signalification/00_ORCHESTRATION.md`, `SIGNAL_ENVELOPE_V1.md`, `DOMAIN_SIGNALIFICATION_MAP.md`, `SWARM_RUNBOOK.md`.
- Ledger (keep `implementation-notes.html` + `progressEvents` current at each phase): `.agent/runs/signalification-phases-3to8-20260604/`.
- Evidence + working openers + audit synthesis: `.agent/runs/signalification-phases-3to8-20260604/evidence/`.
