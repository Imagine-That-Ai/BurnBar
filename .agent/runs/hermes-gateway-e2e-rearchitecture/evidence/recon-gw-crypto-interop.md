I have a complete, exhaustive picture. I now have every wire invariant from three reference implementations (Swift, Kotlin, the existing fork's `qqbot/crypto.py` AESGCM precedent), the real test fixture with concrete vectors, the fixture generator, the fork's module/test conventions, and the dependency state. I can write the precise design brief for the Python crypto interop slice.

---

# RECON: python-swift-ts-crypto-interop (THE CRUX)

## 0. What I read (sources of truth)

| Reference impl | Path | Role for Python |
|---|---|---|
| **Swift (canonical)** | `OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayCrypto.swift` (1–186; PiAgent 188–324) | The spec. CryptoKit hides ECDH/HKDF internals. |
| **Kotlin (blueprint)** | `android/app/src/main/java/com/openburnbar/data/hermes/relay/HermesRelayCrypto{,Hkdf,Ec,Support}.kt` | Best blueprint — does *explicit* ECDH/HKDF/X9.63, exactly what Python must do. |
| **Existing fork crypto precedent** | `~/.hermes/hermes-agent/gateway/platforms/qqbot/crypto.py` (uses `cryptography.hazmat.primitives.ciphers.aead.AESGCM`; confirms `IV(12)‖ct‖tag(16)` = AESGCM's `ct+tag` concatenation) | Confirms library + combined layout. |
| **The shared test vector** | `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Fixtures/HermesRelayWireVector.json` (real values, revision `v1`) | The exact fixture Python must open and that Kotlin already replays. |
| **Vector generator** | `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/HermesRelayCrossPlatformVectorTests.swift` | Defines fields + regen command. |
| **Kotlin interop tests (model to copy)** | `android/app/src/test/java/com/openburnbar/HermesRelayCryptoTest.kt`, `.../data/hermes/relay/HermesRelayWireVectorTest.kt` | The exact test shape Python mirrors. |

`cryptography==46.0.7` is already locked in `~/.hermes/hermes-agent/uv.lock` (transitive). The fork imports it lazily inside functions (`qqbot/crypto.py:35`, `wecom_crypto.py:18`). Platform tests live at `tests/gateway/test_<platform>.py`; `tests/gateway/test_burnbar_plugin.py` already exists.

---

## 1. EXACT WIRE INVARIANTS (byte-for-byte — Python MUST match)

**Curve / keys**
- Curve **NIST P-256 / secp256r1 / prime256v1** (`SECP256R1`).
- Public keys are **X9.63 uncompressed**: 65 bytes, `0x04 ‖ X(32) ‖ Y(32)` big-endian. Swift `x963Representation`; Kotlin builds it manually (`HermesRelayCryptoEc.encodeUncompressedPublicKey`, left-padding affine X/Y to 32B).
- Private key (in the fixture, `recipientPrivateKey`) is Swift `P256.KeyAgreement.PrivateKey.rawRepresentation` = the **big-endian 32-byte scalar `d`** (NOT DER/PKCS8). Kotlin imports it via `BigInteger(1, raw)` + `ECPrivateKeySpec`. **Python must import it via `ec.derive_private_key(int.from_bytes(raw,'big'), SECP256R1())`** — this is the single trickiest interop point.

**ECDH**
- Shared secret = **raw X-coordinate, 32 bytes big-endian** (NOT hashed). CryptoKit `SharedSecret` and JCE `KeyAgreement("ECDH").generateSecret()` both yield this. In Python: `private_key.exchange(ec.ECDH(), peer_public_key)` returns exactly these 32 bytes. Fixture proves `ecdh size == 32`.

**HKDF-SHA256** (used only for key-wrap; the payload/chunk seal uses the symmetric key directly)
- `HKDF-Extract(salt, IKM=sharedSecret)` then `HKDF-Expand(info, L=32)`, hash **SHA-256**, output **32 bytes**.
- **salt = empty** → per RFC 5869, empty salt becomes a HashLen(32)-byte zero string. Swift passes `salt: Data()`; Kotlin makes it explicit (`HermesRelayCryptoHkdf.hkdfExtract`: `if salt.isEmpty -> ByteArray(32)`). Python's `cryptography` `HKDF(salt=b"\x00"*32, ...)` reproduces this exactly. (Do **not** pass `salt=None` — `cryptography` treats `None` as zeros too, but pass explicit 32 zero bytes to match Kotlin and be unambiguous.)
- **info = `b"OpenBurnBar-HermesRelay-KeyWrap-v1|" + aad`** (the *key* AAD bytes appended). Swift `keyWrapSharedInfo` (`:181-185`); Kotlin `keyWrapSharedInfo` (`Support.kt:9`). For PiAgent: `b"OpenBurnBar-PiAgentRelay-KeyWrap-v1|" + aad`.

**AES-256-GCM**
- Key 32 bytes; **nonce/IV = 12 random bytes**; **tag = 16 bytes**.
- `cryptography`'s `AESGCM.encrypt(nonce, plaintext, aad)` returns **`ciphertext ‖ tag(16)`** (tag appended) — matches CryptoKit `SealedBox.ciphertext+tag` and Kotlin `cipher.doFinal` (which appends the tag).

**Combined / envelope layouts**
- **Payload/chunk seal** (`sealToBase64`): wire bytes = **`nonce(12) ‖ ciphertext ‖ tag(16)`**, base64 (standard, with padding, no line wraps). This is CryptoKit `sealed.combined`; Kotlin emits `nonce + cipher.doFinal`. In Python: `base64.b64encode(nonce + AESGCM(key).encrypt(nonce, pt, aad))`.
- **Wrapped key** (`wrapSymmetricKey`): wire bytes = **`ephemeralPubX963(65) ‖ nonce(12) ‖ wrappedKeyCiphertext(32) ‖ tag(16)`** = **125 bytes**, base64. Swift: `ephemeral.publicKey.x963Representation + sealed.combined`. Kotlin: `ephemeralPubX963 + nonce + sealed`. Pinned: `HermesRelayCryptoTest` asserts `bytes.size == 125` and `bytes[0] == 0x04`.
- Unwrap splits: `prefix(65)` = ephemeral pub, `suffix(65..)` = `nonce(12)‖ct(32)‖tag(16)`.

**AAD namespacing (verbatim, UTF-8)** — `prefix | parts.join("|")`:
- Prefix `OpenBurnBar-HermesRelay-v1` (PiAgent: `OpenBurnBar-PiAgentRelay-v1`).
- `requestAAD` = `OpenBurnBar-HermesRelay-v1|request|{uid}|{connectionID}|{requestID}`
- `keyAAD` = `…|key|{uid}|{connectionID}|{requestID}`
- `chunkAAD` = `…|chunk|{uid}|{connectionID}|{requestID}|{sequence}|{kind}` (sequence is decimal int string; kind e.g. `sse`).
- **Key-wrap uses `keyAAD`; payload uses `requestAAD`; each streamed chunk uses its own `chunkAAD`.** AAD is mandatory and authenticated — wrong AAD → GCM tag failure (`AEADBadTagException` in Kotlin → `InvalidTag` in Python).

**Algorithm tag / versions**
- `algorithm = "p256-hkdf-sha256-aesgcm"`, `keyVersion = 1`. Server (`firestore.rules`) and the gateway docs require `relayEncryption == "p256-hkdf-sha256-aesgcm"`, `payloadCiphertext`/`wrappedKey` string fields, `schemaVersion >= 2`, and **no** `path`/`sessionId`/`body`/`error` plaintext (`functions/scripts/test-hermes.mjs:168-178`).

**The fixture (concrete pinned values, revision `v1`):**
```
recipientPrivateKey = base64(0x10 ‖ 0x42*31)                 # 32B scalar
symmetricKey        = base64([ (i*7)%251 for i in 0..31 ])   # AAAH... deterministic
payload (JSON, Swift JSONEncoder order): {"path":"/v1/chat/completions","sessionId":"s-vector","body":"{\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}]}"}
uid/cid/rid = u-vector / c-vector / r-vector ; chunk seq=0 kind="sse" ; chunkPlaintext="data: hello mercury"
```
Note `payloadCiphertext`/`wrappedKey`/`chunkCiphertext` are randomized (random nonce + random ephemeral key), so they are **not byte-reproducible** — Python verifies them by **opening**, and verifies its own seals by **Swift/Kotlin opening them back** (round-trip), exactly as the Kotlin suite does.

---

## 2. PYTHON MODULE SPEC (`cryptography` hazmat)

Place a reusable module in the fork so any platform adapter can seal: **`gateway/platforms/relay_crypto.py`** (sibling of `wecom_crypto.py`; the gateway-wide PR2 home). The BurnBar adapter imports from it. Mirror Swift constants/AAD byte-for-byte.

```python
# gateway/platforms/relay_crypto.py
from __future__ import annotations
import base64, os
from dataclasses import dataclass

_AAD_PREFIX = "OpenBurnBar-HermesRelay-v1"
_KEY_WRAP_INFO_PREFIX = "OpenBurnBar-HermesRelay-KeyWrap-v1|"
ALGORITHM = "p256-hkdf-sha256-aesgcm"
KEY_VERSION = 1
_SYM_KEY_BYTES = 32
_NONCE_BYTES = 12
_X963_LEN = 65
_P256_COORD = 32

def _aad(parts: list[str]) -> bytes:
    return ("|".join([_AAD_PREFIX, *parts])).encode("utf-8")

def request_aad(uid: str, connection_id: str, request_id: str) -> bytes:
    return _aad(["request", uid, connection_id, request_id])

def key_aad(uid: str, connection_id: str, request_id: str) -> bytes:
    return _aad(["key", uid, connection_id, request_id])

def chunk_aad(uid, connection_id, request_id, sequence: int, kind: str) -> bytes:
    return _aad(["chunk", uid, connection_id, request_id, str(sequence), kind])

def generate_symmetric_key() -> bytes:
    return os.urandom(_SYM_KEY_BYTES)

def seal_to_base64(plaintext: bytes, key_data: bytes, aad: bytes) -> str:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    if len(key_data) != _SYM_KEY_BYTES: raise ValueError("symmetric key must be 32 bytes")
    nonce = os.urandom(_NONCE_BYTES)
    ct_tag = AESGCM(key_data).encrypt(nonce, plaintext, aad)   # ct ‖ tag(16)
    return base64.b64encode(nonce + ct_tag).decode()

def open_base64(ciphertext_b64: str, key_data: bytes, aad: bytes) -> bytes:
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    if len(key_data) != _SYM_KEY_BYTES: raise ValueError("symmetric key must be 32 bytes")
    raw = base64.b64decode(ciphertext_b64)
    if len(raw) <= _NONCE_BYTES: raise ValueError("ciphertext too short")
    return AESGCM(key_data).decrypt(raw[:_NONCE_BYTES], raw[_NONCE_BYTES:], aad)

def _hkdf_wrapping_key(shared_secret: bytes, aad: bytes) -> bytes:
    from cryptography.hazmat.primitives.kdf.hkdf import HKDF
    from cryptography.hazmat.primitives import hashes
    return HKDF(
        algorithm=hashes.SHA256(), length=_SYM_KEY_BYTES,
        salt=b"\x00" * 32,                                   # empty salt -> 32 zero bytes (RFC 5869)
        info=_KEY_WRAP_INFO_PREFIX.encode("utf-8") + aad,
    ).derive(shared_secret)

def wrap_symmetric_key(key_data: bytes, recipient_public_key_b64: str, aad: bytes) -> str:
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    if len(key_data) != _SYM_KEY_BYTES: raise ValueError("symmetric key must be 32 bytes")
    recipient = ec.EllipticCurvePublicKey.from_encoded_point(
        ec.SECP256R1(), base64.b64decode(recipient_public_key_b64))   # validates 0x04 + 65B
    eph = ec.generate_private_key(ec.SECP256R1())
    shared = eph.exchange(ec.ECDH(), recipient)                       # 32B X-coord
    wrapping = _hkdf_wrapping_key(shared, aad)
    nonce = os.urandom(_NONCE_BYTES)
    sealed = AESGCM(wrapping).encrypt(nonce, key_data, aad)           # 32 + 16
    eph_x963 = eph.public_key().public_bytes(
        Encoding.X962, PublicFormat.UncompressedPoint)               # 65B 0x04...
    return base64.b64encode(eph_x963 + nonce + sealed).decode()      # 65+12+32+16 = 125

def unwrap_symmetric_key(wrapped_b64: str, private_key_raw32: bytes, aad: bytes) -> bytes:
    from cryptography.hazmat.primitives.asymmetric import ec
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
    env = base64.b64decode(wrapped_b64)
    if len(env) <= _X963_LEN: raise ValueError("wrapped key too short")
    eph_pub = ec.EllipticCurvePublicKey.from_encoded_point(ec.SECP256R1(), env[:_X963_LEN])
    body = env[_X963_LEN:]
    if len(body) <= _NONCE_BYTES: raise ValueError("wrapped key body too short")
    priv = ec.derive_private_key(int.from_bytes(private_key_raw32, "big"), ec.SECP256R1())
    shared = priv.exchange(ec.ECDH(), eph_pub)
    wrapping = _hkdf_wrapping_key(shared, aad)
    return AESGCM(wrapping).decrypt(body[:_NONCE_BYTES], body[_NONCE_BYTES:], aad)
```
*(import `Encoding`/`PublicFormat` from `cryptography.hazmat.primitives.serialization`).* A `PiAgentRelayCrypto`-equivalent is the **same code with prefixes `OpenBurnBar-PiAgentRelay-v1` / `OpenBurnBar-PiAgentRelay-KeyWrap-v1|`** — parameterize the two prefix constants rather than duplicate.

### Six byte-exactness traps (each maps to a reference line)
1. **Raw scalar import** via `derive_private_key(int_be, SECP256R1())` — NOT PKCS8/DER. (Kotlin `recipientPrivateKey()`; fixture `recipientPrivateKey` is 32B.)
2. **ECDH = raw 32B X-coord**: `exchange(ec.ECDH(), pub)`. Never run it through a KDF before HKDF; HKDF *is* the KDF. (Swift `sharedSecretFromKeyAgreement`; Kotlin `ecdh`.)
3. **Empty salt → 32 zero bytes**, not `None`-ambiguous, not omitted. (Swift `salt: Data()`; Kotlin `ByteArray(32)`.)
4. **info = prefix-string ‖ keyAAD-bytes** — concatenate the *bytes*, and use the **keyAAD** (not requestAAD) for wrapping. (Swift `keyWrapSharedInfo`; generator passes `keyAAD` to `wrapSymmetricKey`.)
5. **Combined order**: payload = `nonce‖ct‖tag`; wrapped = `ephPub‖nonce‖ct‖tag`. AESGCM already appends the tag — do **not** reorder or split the tag out. (`qqbot/crypto.py` comment; Kotlin `nonce + ...`.)
6. **base64 = standard alphabet, padded, single-line**; UTF-8 AAD with literal `|`. (Swift `.base64EncodedString()`, Kotlin `NO_WRAP`.)

---

## 3. CROSS-LANGUAGE INTEROP TEST DESIGN

**Shared fixture (already exists, do not regenerate unless revision bumps):** `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Fixtures/HermesRelayWireVector.json`. Vendor a **byte-identical copy** into the fork at `~/.hermes/hermes-agent/tests/gateway/fixtures/HermesRelayWireVector.json` so the fork PR is self-contained (mirror Android's pattern: Android copies it to `android/app/src/test/resources/hermes-relay/`). Regen command (from generator docstring): `swift test --package-path OpenBurnBarCore --filter HermesRelayCrossPlatformVectorTests`, then copy to all three consumers (Android, fork).

**Add `~/.hermes/hermes-agent/tests/gateway/test_relay_crypto.py`** (mirrors `HermesRelayWireVectorTest.kt` + `HermesRelayCryptoTest.kt`):

A. **Swift-sealed → Python opens** (the core direction):
   1. `aad_strings_match`: assert `request_aad/key_aad/chunk_aad(uid,cid,rid[,seq,kind])` byte-equal the fixture `requestAAD/keyAAD/chunkAAD` strings.
   2. `unwraps_swift_wrappedKey`: `unwrap_symmetric_key(fixture.wrappedKey, b64decode(fixture.recipientPrivateKey), key_aad)` == `b64decode(fixture.symmetricKey)`.
   3. `decrypts_swift_payloadCiphertext`: `open_base64(fixture.payloadCiphertext, symKey, request_aad)` decodes to JSON with `path/sessionId/body` == fixture plaintext; also assert it equals `b64decode(fixture.encodedPlaintext)` byte-for-byte.
   4. `decrypts_swift_chunkCiphertext`: `open_base64(fixture.chunkCiphertext, symKey, chunk_aad)` == `fixture.chunkPlaintext`.

B. **Python-sealed → opens back** (proves Python emits valid wire format; the strongest claim, "Swift/TS can open it," is verified transitively because Python's bytes are format-identical and the round-trip below uses the *unwrapped Swift key*):
   5. `python_reseal_round_trip`: unwrap Swift's key, `seal_to_base64("data: reply from python", symKey, chunk_aad(seq=1))`, then `open_base64(...)` back == original (mirrors Kotlin's `re_seals_with_unwrapped_key`).
   6. `python_wrap_then_python_unwrap`: generate a P-256 keypair in Python (export raw scalar via `private_numbers().private_value.to_bytes(32,'big')` and pub via `UncompressedPoint`), `wrap_symmetric_key` then `unwrap_symmetric_key` round-trips; assert wrapped bytes are exactly **125** and `[0]==0x04`.

C. **Adversarial / invariants** (mirror Kotlin):
   7. `wrong_aad_fails`: opening with a mutated AAD raises `cryptography.exceptions.InvalidTag`.
   8. `wrong_recipient_key_fails`: unwrap with a different private scalar raises.
   9. `two_wraps_distinct`: two `wrap_symmetric_key` calls of the same key differ (ephemeral randomization) yet both unwrap.
   10. `combined_shape`: a seal of a 16-byte plaintext base64-decodes to exactly `12+16+16 == 44` bytes.

D. **The true three-way closure (Swift ⇄ Python ⇄ TS), one new gate to add:**
   - **TS side has no relay-crypto impl today** (confirmed: only `apps/console/lib/escrow.ts` does the *vault* ECIES, info `"OpenBurnBar-Escrow-v1"`, salt ∅ — a *different* scheme; the relay `KeyWrap-v1|aad` info does not exist in TS/JS). So "interop with TS" for the relay path requires the TS stream to either (a) add a Node `hermesRelayCrypto.ts` (Node `crypto`: `crypto.createECDH('prime256v1')` or WebCrypto P-256, `hkdfSync('sha256', secret, Buffer.alloc(32), info, 32)`, `createCipheriv('aes-256-gcm', key, nonce)` with `setAAD`), or (b) declare the relay leg Python↔Swift/Kotlin only. **Recommend a tiny shared `relay-vectors/` fixture consumed by Swift, Kotlin, Python, and (new) a Node test** — all four open the same `HermesRelayWireVector.json`. The Python test in this slice is the authoritative new consumer; flag the Node consumer as a dependency for the TS stream (it must use **salt=32 zero bytes, info=`OpenBurnBar-HermesRelay-KeyWrap-v1|`+aad**, not the escrow constants).

**Fork test wiring:** put the fixture loader next to `tests/gateway/_plugin_adapter_loader.py` conventions; gate skips if `cryptography` import fails (matches `qqbot` lazy import). Run via the fork's `python -m pytest tests/gateway/test_relay_crypto.py -q` (ADDING_A_PLATFORM.md §16).

---

## DESIGN BRIEF

1. **Create `~/.hermes/hermes-agent/gateway/platforms/relay_crypto.py`** (PR2, reusable; sibling of `gateway/platforms/wecom_crypto.py`). Public API, byte-exact with Swift `HermesRelayCrypto.swift`: `request_aad/key_aad/chunk_aad`, `generate_symmetric_key`, `seal_to_base64`, `open_base64`, `wrap_symmetric_key`, `unwrap_symmetric_key`. Parameterize the two prefix strings so the same module also serves the PiAgent variant (`OpenBurnBar-PiAgentRelay-v1` / `…-KeyWrap-v1|`). Use `cryptography.hazmat` only (`ec.SECP256R1`, `HKDF(SHA256)`, `AESGCM`); lazy-import inside functions like `qqbot/crypto.py:35`. `cryptography==46.0.7` is already in `uv.lock` — no new dependency.

2. **Constants (copy verbatim):** `ALGORITHM="p256-hkdf-sha256-aesgcm"`, `KEY_VERSION=1`, AAD prefix `"OpenBurnBar-HermesRelay-v1"`, key-wrap info prefix `"OpenBurnBar-HermesRelay-KeyWrap-v1|"`. AAD = `prefix + "|" + "|".join(parts)`, UTF-8. Sources: Swift `:62,178,182`; Kotlin `Support.kt:4-5,7,9`.

3. **`seal_to_base64`/`open_base64`:** AES-256-GCM, 12-byte random nonce, wire = `base64(nonce(12) ‖ AESGCM.encrypt(nonce, pt, aad))` where the result already carries the 16-byte tag. Open = `AESGCM.decrypt(raw[:12], raw[12:], aad)`. Matches Swift `.combined` (`:108-111`), Kotlin `:45,52-53`, `qqbot/crypto.py` layout.

4. **`wrap_symmetric_key`:** ephemeral P-256 keypair → `eph.exchange(ECDH(), recipient)` (raw 32B X-coord) → `HKDF(SHA256, salt=b"\x00"*32, info=key-wrap-prefix+keyAAD, len=32)` → AES-256-GCM seal of the 32-byte key under that wrapping key with the **keyAAD** → wire = `base64(ephPubX963(65) ‖ nonce(12) ‖ ct(32) ‖ tag(16))` = **125 bytes**, `[0]==0x04`. Recipient pub via `EllipticCurvePublicKey.from_encoded_point(SECP256R1(), b64decode(pub))`; ephemeral pub via `public_bytes(X962, UncompressedPoint)`. Matches Swift `:137-149`, Kotlin `:60-80`.

5. **`unwrap_symmetric_key`:** split `prefix(65)`=ephPub, `suffix(65:)`=`nonce(12)‖ct‖tag`; **import the recipient private key from the raw 32-byte big-endian scalar via `ec.derive_private_key(int.from_bytes(raw,'big'), SECP256R1())`** (NOT PKCS8/DER — this is the #1 interop trap; mirrors Kotlin `recipientPrivateKey()` and Swift `rawRepresentation`); ECDH → identical HKDF → `AESGCM.decrypt`. Matches Swift `:152-175`, Kotlin `:82-102`.

6. **HKDF empty-salt rule:** pass `salt=b"\x00"*32` (RFC 5869 empty-salt expansion), `info = b"OpenBurnBar-HermesRelay-KeyWrap-v1|" + aad`, `length=32`, SHA-256. Do not pass `salt=None`. Matches Swift `salt: Data()` (`:141,169`), Kotlin `hkdfExtract` zero-fill (`Hkdf.kt:16`).

7. **Update the BurnBar adapter to seal (PR2):** in `~/.hermes/hermes-agent/plugins/platforms/burnbar/adapter.py`, import from `gateway.platforms.relay_crypto`; before `_post_message` (`:194`) seal the message `text` and before `_create_attachments` (`:166`) seal attachment bytes/filenames; write `payloadCiphertext`/`wrappedKey`/`relayEncryption="p256-hkdf-sha256-aesgcm"`/`schemaVersion>=2` and STOP sending plaintext `text`/`fileName`/`body` (server rules already reject those: `functions/scripts/test-hermes.mjs:168-178`). Requires the adapter to obtain the paired link's recipient public key + per-link keypair (that pairing/key-publishing work is the BurnBar-repo + fork-PR1 slices; this slice supplies the seal primitives they call). Keep the keyless legacy adapter path behind a capability flag for unpaired/legacy servers.

8. **Vendor the shared fixture into the fork:** copy `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Fixtures/HermesRelayWireVector.json` verbatim to `~/.hermes/hermes-agent/tests/gateway/fixtures/HermesRelayWireVector.json`. It is generated by `swift test --package-path OpenBurnBarCore --filter HermesRelayCrossPlatformVectorTests`; Android already consumes it at `android/app/src/test/resources/hermes-relay/`. Treat revision `"v1"` as the contract key — assert it.

9. **Add `~/.hermes/hermes-agent/tests/gateway/test_relay_crypto.py`** mirroring `HermesRelayWireVectorTest.kt` + `HermesRelayCryptoTest.kt`: (A) Python opens Swift's `wrappedKey`→`symmetricKey`, `payloadCiphertext`→`encodedPlaintext`/JSON, `chunkCiphertext`→`chunkPlaintext`; AAD strings byte-match the fixture. (B) Python reseal/round-trip with the unwrapped Swift key; Python `wrap`→`unwrap` round-trip asserting 125-byte/`0x04` envelope. (C) adversarial: wrong-AAD `InvalidTag`, wrong-key fail, two-wraps-distinct, combined-shape `44` bytes for 16-byte plaintext. Lazy-import `cryptography`; run with `python -m pytest tests/gateway/test_relay_crypto.py -q`.

10. **Three-way Swift⇄Python⇄TS closure — flag the missing TS leg:** there is currently **no TS/JS relay-crypto implementation** (only the *vault* escrow in `apps/console/lib/escrow.ts`, which uses different constants: info `"OpenBurnBar-Escrow-v1"`, not `…HermesRelay-KeyWrap-v1|`). For genuine TS interop, the TS stream must add a Node module (`crypto.createECDH('prime256v1')` / WebCrypto P-256, `hkdfSync('sha256', secret, Buffer.alloc(32), info, 32)`, `aes-256-gcm` with `setAAD`) that opens the **same** `HermesRelayWireVector.json`. This Python slice is the authoritative new consumer and the contract the TS leg must match; surface that dependency explicitly. Until then, the verified interop set is **Swift ⇄ Kotlin ⇄ Python** (all three open one fixture), which is sufficient for the BurnBar adapter (Python) ⇄ Mac/iOS host (Swift) path.

11. **Hard invariants (do not drift — pin all in the test):** P-256/secp256r1; X9.63 uncompressed pubkeys 65B `0x04‖X‖Y`; raw 32B big-endian private scalar (`derive_private_key`); ECDH = raw 32B X-coord; HKDF-SHA256 salt=32×`0x00`, info=keywrap-prefix+keyAAD, out 32B; AES-256-GCM nonce 12B + tag 16B; payload combined `nonce‖ct‖tag`, wrapped `ephPub(65)‖nonce(12)‖ct(32)‖tag(16)`=125B; base64 standard padded single-line; AAD namespaced `prefix|kind|uid|connectionID|requestID[|seq|kind]` UTF-8; **keyAAD for wrap, requestAAD for payload, per-chunk chunkAAD**; `algorithm="p256-hkdf-sha256-aesgcm"`, `keyVersion=1`.

**Key file paths (absolute):**
- Swift spec: `/Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarCore/Sources/OpenBurnBarCore/SharedModels/HermesRelayCrypto.swift`
- Kotlin blueprint: `/Users/albertonunez/Documents/Windsurf/BurnBar/android/app/src/main/java/com/openburnbar/data/hermes/relay/HermesRelayCrypto{,Hkdf,Ec,Support}.kt`
- Shared fixture: `/Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Fixtures/HermesRelayWireVector.json`
- Fixture generator: `/Users/albertonunez/Documents/Windsurf/BurnBar/OpenBurnBarCore/Tests/OpenBurnBarCoreTests/HermesRelayCrossPlatformVectorTests.swift`
- Kotlin interop tests (to mirror): `/Users/albertonunez/Documents/Windsurf/BurnBar/android/app/src/test/java/com/openburnbar/HermesRelayCryptoTest.kt`, `/Users/albertonunez/Documents/Windsurf/BurnBar/android/app/src/test/java/com/openburnbar/data/hermes/relay/HermesRelayWireVectorTest.kt`
- Fork crypto precedent: `/Users/albertonunez/.hermes/hermes-agent/gateway/platforms/qqbot/crypto.py`, `/Users/albertonunez/.hermes/hermes-agent/gateway/platforms/wecom_crypto.py`
- New Python module (to create): `/Users/albertonunez/.hermes/hermes-agent/gateway/platforms/relay_crypto.py`
- New Python test (to create): `/Users/albertonunez/.hermes/hermes-agent/tests/gateway/test_relay_crypto.py` (+ fixture copy under `tests/gateway/fixtures/`)
- Fork burnbar adapter to update: `/Users/albertonunez/.hermes/hermes-agent/plugins/platforms/burnbar/adapter.py`
- Existing fork burnbar test: `/Users/albertonunez/.hermes/hermes-agent/tests/gateway/test_burnbar_plugin.py`
- Dep lock confirming `cryptography==46.0.7`: `/Users/albertonunez/.hermes/hermes-agent/uv.lock:818`