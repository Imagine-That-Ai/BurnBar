# BurnBar HPKE v3 — Kotlin/Android lane handoff

Lane scope: **Android Hermes relay crypto + tests only.** No edits to Python,
Swift, shared docs, or the canonical fixture (vector lane owns the v3 fixture).

## Android participation decision: **PARTICIPATES → implement v3 parity**

Android is squarely in the Hermes relay crypto path, so the kotlin lane
implements the RFC 9180 HPKE Auth v3 suite rather than writing a no-op proof.
Evidence from the Android source:

- `android/app/src/main/java/com/openburnbar/data/hermes/relay/HermesRelayCrypto.kt`
  is the canonical Android port of the shared relay crypto — byte-for-byte with
  the Swift source of truth and the Python mirror (`gateway/crypto/relay_e2ee.py`).
  It already implements v1 (anonymous ECIES) and v2 (authenticated 2-DH,
  HPKE-AuthEncap-shaped) wrap/unwrap, `keyAAD`, AES-256-GCM seal/open, and the
  two-key `gatewayRelaySafetyCode`.
- Android already **consumes the shared cross-language vector**:
  `HermesGatewayV2VectorTest` opens the Swift-emitted v2 gateway envelopes in
  `app/src/test/resources/hermes-relay/HermesGatewayWireVector.json`. A v3 suite
  must therefore stay byte-compatible with the shared JSON fixtures.

Current wire reality (unchanged by this lane):

- Android **emits v1** in production: `HermesRelayClient.wrapSymmetricKey(...)`
  and `HermesIrohRelayTransportSendSupport` call `wrapSymmetricKey` without a
  `senderPrivateKey`, and advertise `relayKeyVersion = HermesRelayCrypto.KEY_VERSION`
  (== 1) / `relayEncryption = ALGORITHM` (`p256-hkdf-sha256-aesgcm`).
- Android is **v2-open-capable** (proven by the gateway vector test) and is now
  **v3-parity-ready** (this lane), but does **not** yet advertise or emit v2/v3
  on the wire. There is no production `unwrapSymmetricKey` caller to extend with
  a version branch — inbound open is exercised by the vector tests today.

## Frozen v3 contract as implemented (byte-exact with Python/Swift target)

| Item | Value |
|------|-------|
| Mode | HPKE **Auth** (`mode_auth = 0x02`) |
| KEM | DHKEM(P-256, HKDF-SHA256) (`kem_id = 0x0010`) |
| KDF | HKDF-SHA256 (`kdf_id = 0x0001`) |
| AEAD | AES-256-GCM (`aead_id = 0x0002`) |
| `relayKeyVersion` | `3` (`HermesRelayCrypto.KEY_VERSION_V3`) |
| `relayEncryption` | `hpke-auth-p256-hkdfsha256-aes256gcm` (`HermesRelayCrypto.ALGORITHM_V3`) |
| `info` | `"OpenBurnBar-HermesRelay-HPKE-v3\|" ‖ key_aad` |
| `aad` | `key_aad` |
| `pt` | 32-byte content key |
| `ct` (`wrappedKey`) | HPKE Auth single-shot `Seal(pt, aad)` → 48 B (32 ‖ 16 tag) |
| `enc` | X9.63 uncompressed ephemeral key, 65 B (`0x04 ‖ X ‖ Y`) |
| `senderPublicKey` | X9.63 sender key, **diagnostics only** — never the auth key |
| Auth rule | `open_v3(recipientPriv, pinnedSenderPub, enc, wrappedKey, key_aad)` |

The implementation hand-rolls RFC 9180 on the JCE primitives v1/v2 already use
(`HermesRelayCryptoEc` ECDH + X9.63 coding, `HermesRelayCryptoHkdf`
extract/expand, JCE `AES/GCM/NoPadding`) — **zero new dependencies**, byte
controllable, mirroring the Python `cryptography`-primitive approach. The KEM DH
legs (`ECDH(eph,R) ‖ ECDH(skS,R)`, concat, dh1 first) and X9.63 point encoding
are identical to the proven v2 path; only the RFC 9180 labeled KDF + key
schedule + suite IDs are new. Each P-256 DH leg is left-padded to 32 bytes
(RFC 9180 §7.1.1) — strictly more correct than v2's reliance on the provider.

## Files changed (Android lane only)

| File | Change |
|------|--------|
| `android/app/src/main/java/com/openburnbar/data/hermes/relay/HermesRelayCryptoHpkeV3.kt` | **NEW** — RFC 9180 HPKE Auth engine: `AuthEncap`/`AuthDecap`, mode_auth key schedule, labeled KDF, single-shot AEAD, `sealKey`/`openKey`. |
| `android/app/src/main/java/com/openburnbar/data/hermes/relay/HermesRelayCrypto.kt` | **EDIT (+~70 lines)** — `KEY_VERSION_V3`, `ALGORITHM_V3`, `RelayKeyWrapV3Wire`, base64 `wrapSymmetricKeyV3` / `unwrapSymmetricKeyV3`. v1/v2 byte-unchanged. |
| `android/app/src/test/java/com/openburnbar/data/hermes/relay/HermesRelayCryptoHpkeV3Test.kt` | **NEW** — v3 test suite (round-trip, structural, 6 negatives, v2 no-regression, gated shared-vector consumer). |

No other files touched. Working tree was clean before edits (only untracked
`.pytest-cache/`, left as-is); no concurrent lane changes existed under the
android relay dir.

## Tests

Command (offline, warm Gradle 8.9 cache + Android SDK 35):

```bash
cd android && ./gradlew :app:testDebugUnitTest \
  --tests "com.openburnbar.data.hermes.relay.HermesRelayCryptoHpkeV3Test" \
  --tests "com.openburnbar.data.hermes.relay.HermesGatewayV2VectorTest" \
  --tests "com.openburnbar.HermesRelayCryptoTest" \
  --tests "com.openburnbar.data.hermes.relay.HermesRelayWireVectorTest" \
  --offline --console=plain
```

v3 coverage (`HermesRelayCryptoHpkeV3Test`):

- `v3_wire_markers_match_the_frozen_contract` — version 3 + algorithm string.
- `seal_then_open_round_trips_and_has_the_canonical_wire_shape` — `enc`=65 B
  (`0x04`), `wrappedKey`=48 B, `senderPublicKey`=65 B, content key recovered.
- `seal_is_randomized_but_both_envelopes_open_to_the_same_key` — fresh ephemeral.
- Negatives (each mutates exactly one authenticated input → rejected):
  `wrong_pinned_sender`, `wrong_recipient`, `wrong_aad`, `mutated_enc`,
  `mutated_wrappedKey`, `a_v3_envelope_cannot_be_opened_as_v2` (domain sep).
- `v2_authenticated_wrap_unwrap_still_round_trips` — no v2 regression.
- `shared_v3_vector_opens_when_the_vector_lane_hands_it_off` — consumes the
  vendored canonical fixture at `hermes-relay/HermesGatewayWireVectorV3.json`;
  asserts cross-language `symmetricKey` recovery + payload open.

```
RESULT: PASS — BUILD SUCCESSFUL in 8s (offline focused relay run after vector
vendoring). 40 tests, 40 passed, 0 skipped, 0 failures, 0 errors.
  HermesRelayCryptoHpkeV3Test  tests=11 skipped=0 failures=0 errors=0
  HermesGatewayV2VectorTest    tests=9  skipped=0 failures=0 errors=0  (v2 no-regression)
  HermesRelayCryptoTest        tests=14 skipped=0 failures=0 errors=0  (v1/core no-regression)
  HermesRelayWireVectorTest    tests=6  skipped=0 failures=0 errors=0  (v1 vector no-regression)
```

## Independent RFC 9180 conformance audit

A 5-lens adversarial byte-conformance review of `HermesRelayCryptoHpkeV3.kt`
(each lens tasked with finding any deviation that would silently break Swift /
Python interop) returned **5/5 conforms, zero deviations**:

- §4 labeled KDF + suite IDs — KEM/HPKE `suite_id` bytes, `HPKE-v1` framing, and
  per-layer suite binding (KEM derivations use the KEM suite, key schedule uses
  the HPKE suite) all correct.
- §4.1 DHKEM AuthEncap/AuthDecap — ephemeral DH leg first, concat (not XOR),
  `kem_context = enc‖pkRm‖pkSm`, decap binds the **wire** `enc` (no re-encoding
  that could mask a mutation), X9.63 (not DER), 32-byte left-pad.
- §5.1 KeySchedule (mode_auth) — `mode = 0x02`, `secret` salt/ikm not swapped,
  `Nk=32`/`Nn=12`. Cross-checked with an independent Python HKDF re-impl; the
  canonical AES-256 `psk_id_hash` constant (`8fc3aeb8…402112`, which any
  CryptoKit/pyca peer derives identically) matched.
- §5.2/§6.1 single-shot AEAD — `nonce = base_nonce` at seq 0 (not randomized),
  48-byte `wrappedKey`, `key_aad` double-bound in both `info` and the AEAD aad;
  info prefix hex-confirmed byte-identical to Swift `hpkeV3Info`.
- RFC 5869 HKDF core — reproduced RFC 5869 A.1/A.3 known-answer vectors exactly;
  empty salt = 32 HashLen zero bytes; `leftPadTo` cannot corrupt a 32-byte X.

This byte-level review found the construction correct, and empirical
cross-implementation validation is now live through the vendored canonical
vector.

## Vector / fixture status

- **Shared canonical v3 vector (`HermesGatewayWireVectorV3.json`): vendored and
  consumed by Android.** Android does not author it; the fixture is copied from
  the Hermes/Python vector lane into `app/src/test/resources/hermes-relay/`.
- v3 correctness is covered by self round-trip + negative vectors +
  RFC-9180-by-construction review + empirical byte-parity with the canonical
  Swift/Python fixture.
- v1/v2 fixtures remain green (`HermesRelayWireVector.json`,
  `HermesGatewayWireVector.json`).

## Release gate — before Android emits/advertises v3 on the wire

All must hold:

1. Keep the vendored `HermesGatewayWireVectorV3.json` consumer
   (`shared_v3_vector_opens_...`) green on Android (real cross-language parity).
2. Python lane (workstream 1) ships v3 + capability negotiation so the gateway
   advertises/negotiates v3 for paired peers that support it.
3. First-pairing two-key safety code re-verified for the v3 pin.

Then flip these Android sites (currently v1) to v3:

- `relay/HermesRelayClient.kt:257` — `wrapSymmetricKey(...)` → `wrapSymmetricKeyV3(...)`
  with the pinned sender identity; `:269` emit `KEY_VERSION_V3` / `ALGORITHM_V3`;
  `:64` parse already handles the version int.
- `relay/HermesIrohRelayTransportSendSupport.kt:31` wrap → v3; `:45` emit version.
- `relay/HermesIrohRelayTransport.kt:120-122` — capability validation pins
  `relayEncryption == ALGORITHM` (v1); accept the negotiated v3 marker.
- Inbound open: add a `relayKeyVersion == 3 → unwrapSymmetricKeyV3(pinned sender)`
  branch wherever gateway inbound sealed events are opened (no such production
  caller exists today; wire it with the gateway-open consumer). Keep v1/plaintext
  refused on paired links.

## Residual risk

- **Final cross-language byte-parity is empirical on Android through the vendored
  canonical vector.** RFC 9180 guarantees interop by construction; the 5-lens
  byte-conformance audit (above) substantially de-risks a silent
  label/suite/ordering mismatch; and the vector test now catches fixture drift.
  The contract literals were also confirmed byte-identical to the concurrent
  Swift lane (`relayEncryptionV3`, the `HPKE-v3|` info prefix). Still, do not
  flip the wire gate unless the shared vector remains green, gateway negotiation
  is shipped, and the safety code path is re-verified.
- KCI / static-key / metadata limits are the inherent RFC 9180 `AuthDecap` bounds
  (identical to v2); documented, not a regression.
- v3 is purely additive; v1/v2 are byte-unchanged with an explicit no-regression
  test, so no risk to shipped traffic.
