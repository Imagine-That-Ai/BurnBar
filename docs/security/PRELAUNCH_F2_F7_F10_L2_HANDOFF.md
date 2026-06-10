# Handoff — F2 / F7 / F10 / L2 pre-launch remediation

**Branch:** `security/prelaunch-f2-f7-f10-l2` (5 work commits + this handoff doc on top of `main` @ `8a9f8ac47`)
**Status doc:** [`PRELAUNCH_AUDIT_REMEDIATION_2026-06-09.md`](./PRELAUNCH_AUDIT_REMEDIATION_2026-06-09.md) (status matrix near the top)
**Date:** 2026-06-09

Read this top-to-bottom before touching the gated work. The cryptographic/protocol
**cores are shipped, tested, and dormant** behind default-off capability gates;
your job is to wire the app/mobile/device layers to them **without changing the
wire invariants** in §3 (those are byte-identical across Swift, Kotlin, and the
TypeScript server — a divergence is a fail-open).

---

## 0. Verify the current green state first

```bash
# Shared Swift core (the cores + their tests live here) — fully runnable
cd OpenBurnBarCore && swift test            # 1442 pass / 3 skip

# Firebase functions (F2 server + L2 server) — fully runnable
cd functions && npx tsc --noEmit && npx vitest run   # 435 pass / 4 skip
#   NB: the `::error::` lines in vitest output are intentional guard-fixture
#   assertions (region/collection-group guards), NOT failures.

# Android iroh-relay module (attestation/keyKind wire fields) — needs the SDK:
cd android && ANDROID_HOME=$HOME/Library/Android/sdk \
  ./gradlew :openburnbar-iroh-relay:compileDebugKotlin :openburnbar-iroh-relay:testDebugUnitTest
```

The Mac app (`AgentLens`), iOS app (`OpenBurnBarMobile`), and the full Android app
compile only via xcodebuild / a full gradle build — **none of the gated work below
is verifiable with `swift test`**; budget xcodebuild/gradle + a physical device.

---

## 1. What shipped this pass (reuse these — do not re-implement)

| Commit | Area | New public API (file) |
|---|---|---|
| `c38e2522f` | F2 core | `PhoneControlSigningKeyKind` (in `HermesRealtimeRelayTypes.swift`); `PhoneControlVerifyingKey`, `PhoneControlPeerNodeIdDerivation`, `ComputerUsePhoneControlSigner.isValidAuthoritySignature/signAuthorityPayloadP256` (`PhoneControlSigningKey.swift`); `PhoneControlStepUpPolicy`, `AgentDesktopCapability.biometricStepUpRequired` (`PhoneControlStepUpPolicy.swift`) |
| `f72b85c0c` | F2 server | `parsePhoneControlSigningKeyKind`, `requirePhoneControlAuthorityPublicKey`, keyKind-aware `requireDerivedPhoneControlPeerNodeId`; atomic revoke + receipt in `revokeEscrowDeviceTrust` (`functions/src/callables/computerUseSecurity.ts`) |
| `2c887e3d0` | L2 | `gatewayPopSignablePayloadV2`, `canonicalGatewayQueryString`, `gatewayPopVersion`, `parseGatewayPopVersionCapability`; `popVersion` on `HermesGatewayClientDoc` (`functions/src/callables/hermesGateway.ts`, `functions/src/hermesGateway.ts`) |
| `b592811dd` | F7+F10 core | `MediaFrameAEAD` + `MediaFrameAeadNegotiation` (`OpenBurnBarMedia/MediaFrameAEAD.swift`); `ControlFrameSeal` + `ControlFrameSealNegotiation` (`OpenBurnBarComputerUseCore/ControlFrameSeal.swift`) |
| `d52ca1420` | Android + doc | `attestationHashBlake3` + `keyKind` on Kotlin `HermesRealtimeRelayAuthorityEnvelope` (`android/openburnbar-iroh-relay/.../HermesRealtimeRelayFrame.kt`) |

Tests for each live next to them (`*Tests.swift`, `*.test.ts`).

---

## 2. Capability gates (all default-OFF; both peers must advertise)

| Gate constant | Finding | Where to advertise |
|---|---|---|
| `keyKind` absent ⇒ `ed25519` | F2 | controller record `signingKeyKind`; envelope `keyKind` |
| `media_frame_aead_v1` | F7 | mirror/presence `streamingCapabilities` (and the **missing Mac→phone** advertisement) |
| `control_seal_v1` | F10 | host.register / presence capabilities array |
| `popVersion >= 2` | L2 | client doc, captured at device/start + approve |

Nothing emits the new format until both sides advertise, so the tree is safe to
land as-is.

---

## 3. WIRE INVARIANTS — must stay byte-identical (Swift = Kotlin = TS)

- **Signed authority payload:** `UTF8(intentHashHex) ‖ u64BE(counter) ‖ i64BE(timestampMs)`.
- **Signature carrier:** the `signatureEd25519` field. Ed25519 ⇒ raw 64-byte sig, base64. SE-P256 ⇒ **raw `r‖s` 64-byte ECDSA** sig, base64, with `keyKind:"se-p256"`. (Node verifies raw ECDSA with `dsaEncoding:'ieee-p1363'`; JCA emits DER — convert.)
- **peerNodeId derivations** (`PhoneControlPeerNodeIdDerivation` Swift ↔ `requireDerivedPhoneControlPeerNodeId` TS):
  - `ios-phone-<hex(rawKey[0..<12])>`
  - `android-phone-<sha256hex(rawKey)[0..<24]>`
  - `ios-se-<sha256hex(x963Key)[0..<24]>`
  - `android-se-<sha256hex(x963Key)[0..<24]>`
  - Ed25519 published key = 32-byte raw; SE-P256 published key = **65-byte x9.63** (`0x04‖X‖Y`).
- **MediaFrameAEAD envelope:** `"OBMFA1"(6) ‖ 0x01 ‖ AES-GCM.combined(nonce12‖ct‖tag16)`. AAD = `"OpenBurnBar-MediaFrameAEAD-v1|" ‖ streamClass ‖ 0x7C ‖ u8(kind) ‖ u32BE(gopID) ‖ u32BE(frameIndex)`. HKDF-SHA256 info `"OpenBurnBar-MediaFrameAEAD-v1"`, 32-byte key.
- **ControlFrameSeal envelope:** `"OBCFS1"(6) ‖ 0x01 ‖ AES-GCM.combined`. AAD = `"OpenBurnBar-ControlFrameSeal-v1|" ‖ peerNodeId ‖ 0x7C ‖ frameType`. HKDF info `"OpenBurnBar-ControlFrameSeal-v1"`.
- **PoP v2 payload:** `["OpenBurnBar.HermesGatewayPoP.v2", tokenHash, METHOD, path, canonicalQuery, bodyHash, nonce, timestamp].join("\n")`, header `x-openburnbar-pop-version: 2`. `canonicalQuery` = decoded params sorted by key then value, joined `key=value` with `&` (no percent re-encoding).

When you add the Kotlin/Python mirrors, freeze a **cross-language KAT** (pattern:
`OpenBurnBarCore/Tests/.../Fixtures/BurnBarHpkeV3Vector.json`). ⚠️ ECDSA P-256 is
non-deterministic — a KAT must *verify a frozen signature*, never assert signature equality.

---

## 4. Gated next steps (precise targets)

### F2 — hardware-bind + step-up (needs a physical biometric/SE device)
1. **Mac receiver** `AgentLens/Services/ComputerUse/PhoneControlAuthorityValidator.swift`:
   - `peerPublicKeys: [String: Curve25519.Signing.PublicKey]` (L80) → store `PhoneControlVerifyingKey`.
   - `registerPeerDetailed` (L171) + the inline Ed25519 verify in `validate(...)` (L352–365) → use `ComputerUsePhoneControlSigner().isValidAuthoritySignature(...)`.
   - `ControllerKeyPinStore.verifyOrPin` pins `base64(rawRepresentation)` — for SE keys pin `base64(x963Representation)`.
   - Shorten `authorityMaxLifetime` default (L109, 300 → ~120) and re-run `controlClassify` registration per session in `ComputerUseSessionCoordinator`.
2. **Mac provider** `PhoneControlAuthorityProvider.swift` `fetchPublicKey` (L44–101): read `signingKeyKind`, build `try PhoneControlVerifyingKey(kind:publicKeyRepresentation:)`.
3. **iOS signer** `OpenBurnBarMobile/Services/ComputerUse/PhoneControlSender.swift` `PhoneControlSigningKeyStore` (L659–732): mint `SecureEnclave.P256.Signing.PrivateKey` with `.biometryCurrentSet` access control; persist its `dataRepresentation` (the wrapped SE blob, **not** a raw key); publish x9.63 pubkey + `keyKind:"se-p256"`; set `HermesRealtimeRelayAuthorityEnvelope(keyKind:)`; sign → `signature.rawRepresentation`. peerNodeId via `PhoneControlPeerNodeIdDerivation.derive(.secureEnclaveP256, .iOS, x963)`.
4. **Android signer** `android/.../data/computeruse/PhoneControlSignerSign.kt` + `PhoneControlAuthorityPublisher.kt`: P-256 Keystore key with `setIsStrongBoxBacked(true)` + `setUserAuthenticationRequired(true)`; DER→raw r‖s conversion; emit keyKind; also add keyKind/attestation to the **app-side** model `PhoneControlSignerModels.kt:118` (the iroh-relay wire model is already done).
5. **Step-up enforcement:** in `PhoneControlReceiver`/validator, gate sensitive actions on `PhoneControlStepUpPolicy.requiresExplicitLocalAuthProof(capabilities:keyKind:)` — SE-signed envelopes satisfy step-up implicitly; legacy keys must attach the existing local-auth proof.
6. **Publish call sites send `keyKind`:** iOS `ComputerUseSecurityCallableClient.publishPhoneControlAuthority`, Android `ComputerUseSecurityCallableClient.kt`.

### F7 — per-frame media AEAD
1. **Shared secret:** ECDH between the Mac P-256 relay key (`HermesRelayKeyStore` in `AgentLens/Services/CloudSync/HermesRelayHostService.swift`) and the phone P-256 relay sender key (`OpenBurnBarMobile/Services/HermesGatewayRelayKeypair.swift` / Android `HermesRelayKeyStore.kt`); feed into `MediaFrameAEAD.deriveSessionKey`. (Or deliver the media key via `sealKeyV3` at mirror-accept.)
2. **Mac→phone capability advertisement (currently MISSING):** `AgentLens/Services/Media/MercuryRouter.swift` heartbeat reply (~L915–930) and `mediaMirrorAck` don't send `streamingCapabilities`; add `media_frame_aead_v1` there so the negotiator runs both directions.
3. **Seal before chunk:** `AgentLens/Services/Media/MacFileTransferService.swift` `MercuryControlStreamMediaSink.write(frame:)` (L489) / `write(frameV2:)` (L502) — seal the encoded bytes before `sendEncodedFrame`'s base64+chunk.
4. **Open:** iOS `MediaControlStreamCoordinator.readLoop` `.mediaStreamFrame` (L525) before decode; Android `MediaControlFrameDispatcher.handleStreamFrame`.
5. **Kotlin `MediaFrameAEAD` mirror + KAT.**

### F10 — control-frame seal
1. The HPKE session key is the per-request `keyData` from `HermesRelayAuthenticatedRequestOpener.open(...)` (`OpenBurnBarCore/.../HermesRelayAuthenticatedRequest.swift`). The control lane currently **skips** the seal (`OpenBurnBarMobile/Services/IrohRelay/HermesIrohRelayTransport.swift` `openComputerUseControlStream` L316 — "skips the chat encrypt/seal envelope").
2. **Seal** in iOS/Android `PhoneControlSender` (mirror the chat sealer `MobileHermesAuthenticatedRelayRequestSealer.seal`); **open** in `AgentLens/Services/IrohRelay/IrohRelayRequestHandler.swift` `serve()` control arm (L244–269) before `controlDispatcher`.
3. Advertise `control_seal_v1`; Kotlin `ControlFrameSeal` mirror.

### L2 — adapter v2 signer (out of this repo)
The adapter `tools/hermes-platform-burnbar/adapter.py` (and the byte-identical copy in `~/.hermes/hermes-agent/plugins/platforms/burnbar/adapter.py`) currently signs **only a Bearer header — no PoP at all**, and ships as a vendored `.pyc`. Add the PoP signer (v1 + v2, signing the §3 canonical query for GET), then re-vendor: hermes-agent fork commit → bump `third_party/hermes-agent/manifest.json` `pinnedCommit` + `vendoredSourceTreeSha256` → `scripts/ci/verify-vendored-agent-source.sh` passes.

### Extra credit
- Android **attestation reader** (no `MobileAppCheckAttestationReader` equivalent exists) + an Android **Remote Config read** (Android reads no RC today) → attach the digest in `android/.../PhoneControlSender.kt` envelope builders, then ramp `computer_use_phone_control_attestation_required`.
- iOS `sign(remoteUnlockSession:)` (`PhoneControlSender.swift` L331–366) still omits the attestation field.
- Full-key `peerNodeId` migration + Mac re-pair UX (`ControllerKeyPinStore.clearPin` has no production callers yet).

---

## 5. F5 launch-block gate (the "AI safety guard" — already correct, leave it)

`scripts/ci/verify-vendored-agent-source.sh` **fails closed (exit 1)** while
`third_party/hermes-agent/manifest.json` `pendingHardening.blocking: true`, and is
wired into `scripts/ci/verify-ops-readiness.sh`. The C-4 command-guard lives in the
separate `NousResearch/hermes-agent` fork; ops-readiness cannot pass until it's
merged + re-vendored + `blocking:false`. Verified failing closed this pass — do not
flip it from this repo.

---

## 6. Gotchas (cost me time — save yourself)

- **Android gradle needs `ANDROID_HOME=$HOME/Library/Android/sdk`** (no `local.properties`).
- **PoP nonce must be 16–160 chars** (`/^[A-Za-z0-9._:-]{16,160}$/`); short nonces 401 as `missing_pop_nonce`.
- **SourceKit shows false `No such module 'XCTest'/'OpenBurnBarCore'`** in single-file diagnostics — ignore; `swift build`/`swift test` is ground truth.
- **ECDSA P-256 is randomized** — KATs verify a frozen sig, never assert equality.
- **`PhoneControlAuthorityValidator` + mobile signers are app/mobile targets** — `swift test` does NOT cover them; they have heavy `AgentLensTests`/Android unit suites you must run via xcodebuild/gradle before claiming done.
- **Two Kotlin authority models:** iroh-relay `HermesRealtimeRelayFrame.kt:1208` (done) vs app-side `PhoneControlSignerModels.kt:118` (still needs keyKind/attestation).
- **Commits on this branch are NOT clean per-finding diffs.** Concurrent agents were editing the tree, and `git add -A` swept their unrelated work into every commit (AgentLens InsightEngine/QuotaSettings/AgentsSettingsView UI, widget snapshots + LiveActivity, Mercury transfer thumbnails, Android Aurora components, BurnBarStatusIntent). Scope the security work by the **files named in §1**, not by `git show <commit>`.
- The server **does not** verify proof-of-possession of the controller private key in `publishPhoneControlAuthority` (only peerNodeId-from-pubkey derivation) — out of scope here, but note it if you touch that path.
