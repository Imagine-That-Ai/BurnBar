I now have every exact change point on both sides. I have all the facts to produce the design brief.

---

# Adapter-and-Reusable-SDK slice — findings + design brief

## What I confirmed (load-bearing facts)

**Canonical adapter:** the BurnBar-repo `tools/hermes-platform-burnbar/adapter.py` (33 KB, Jun 3) is newer/larger than the fork copy `plugins/platforms/burnbar/adapter.py` (24.8 KB, Jun 1). `smoke_local.py:install_plugin` (lines 194-199) **copies** `adapter.py`, `__init__.py`, `plugin.yaml`, `README.md` from the repo dir into the fork checkout — so the BurnBar repo is the source of truth and the fork plugin is a generated mirror. The crypto module is the one new file that is *not* copied by `install_plugin`, so it must live in the fork and be imported by the adapter; `install_plugin` must be extended to copy it too.

**Crypto primitives verified end-to-end in Python.** The fork ships `cryptography==46.0.7` (transitively, via `PyJWT[crypto]`), and I ran a byte-exact round-trip proving Python reproduces `HermesRelayCrypto` (`OpenBurnBarCore/.../HermesRelayCrypto.swift`) wire format precisely:
- `wrapSymmetricKey` envelope = `ephemeral_pub_X963(65B) ‖ AES-GCM.combined(nonce12 ‖ ct ‖ tag16)` → 125 B for a 32-B key. Python `eph.public_key().public_bytes(X962, UncompressedPoint) + nonce + AESGCM(wrapkey).encrypt(nonce, sym, aad)` is identical.
- HKDF: `salt=b""`, `info = b"OpenBurnBar-HermesRelay-KeyWrap-v1|" + aad`, SHA-256, 32 B.
- Seal: `combined = nonce(12) ‖ AESGCM(symKey).encrypt(nonce, plaintext, aad)`; AAD namespacing `"OpenBurnBar-HermesRelay-v1|<part>|<part>…"`.
- `from_encoded_point(SECP256R1(), env[:65])` opens the ephemeral key; ECDH `exchange` yields the 32-B X-coordinate shared secret.

**CRITICAL dependency gotcha:** the fork pins exact versions and `cryptography` is **not** in the declared `dependencies` list in `pyproject.toml` (only pulled by `PyJWT[crypto]==2.12.1`). The module must import `cryptography` lazily with a clear actionable error, and the fork PR must add an explicit `cryptography==46.0.7` pin (mirror the `HTTPX_AVAILABLE` guard pattern at `adapter.py:23-29`).

**Per-link routing already exists.** `hermes_gateway_events.targetClientId` (`legacy.ts:628`, filtered at `hermesGateway.ts:462`) lets the phone address one specific agent client. This is the hook for per-link sealing: the phone seals an event to *one* agent's published pubkey and sets `targetClientId`.

**Companion-PR interop anchor:** the iOS phone already seals with this exact API at `OpenBurnBarMobile/Services/HermesService.swift:3872-3882` (`sealToBase64` + `wrapSymmetricKey` + fields `payloadCiphertext`/`wrappedKey`/`relayEncryption`), and the Mac host opens at `AgentLens/Services/CloudSync/HermesRelayHostService.swift:619-656`. The phone publishes/reads a peer relay pubkey via `relayPublicKey` (`HermesService.swift:452,3063,3836`). My Python module is the **agent-side mirror** of that pattern.

**Existing platform-crypto precedent layout:** `gateway/platforms/qqbot/crypto.py` (AES-256-GCM helpers) + re-export in `qqbot/__init__.py:33`. The reusable module should live as a sibling shared file (so any adapter imports it), not inside the burnbar plugin dir.

---

## DESIGN BRIEF

### A. New reusable crypto module (FORK, PR2) — `gateway/platforms/relay_crypto.py`

1. **Create `/Users/albertonunez/.hermes/hermes-agent/gateway/platforms/relay_crypto.py`** — a dependency-light, platform-agnostic mirror of `HermesRelayCrypto.swift`. Lazy-import `cryptography` at call time; raise `RelayCryptoUnavailable("pip install cryptography>=46")` if absent (mirror `adapter.py:23-29` `HTTPX_AVAILABLE`). Public API (so ANY adapter adopts it):
   - `ALGORITHM = "p256-hkdf-sha256-aesgcm"`, `KEY_VERSION = 1`, `SYMMETRIC_KEY_BYTES = 32`.
   - `generate_private_key() -> RelayPrivateKey` and class `RelayPrivateKey` with `.raw_representation: bytes` (32-B `private_numbers` big-endian) and `.public_key_base64() -> str` (X9.63 uncompressed, 65 B, base64). Construct from raw via `RelayPrivateKey.from_raw(bytes)`.
   - `aad(*parts, namespace="OpenBurnBar-HermesRelay-v1") -> bytes` → `f"{namespace}|" + "|".join(parts)`. Provide `request_aad(uid, conn, req)`, `key_aad(...)`, `chunk_aad(uid, conn, req, seq, kind)` helpers byte-identical to Swift `:81-97`.
   - `seal_to_base64(plaintext: bytes, key: bytes, aad: bytes) -> str` → `base64(nonce12 ‖ AESGCM(key).encrypt(nonce, plaintext, aad))`.
   - `open_base64(ciphertext_b64: str, key: bytes, aad: bytes) -> bytes`.
   - `wrap_symmetric_key(key: bytes, recipient_public_key_b64: str, aad: bytes) -> str` → ephemeral P-256, ECDH X-coord (32 B), `HKDF(SHA256, salt=b"", info=b"OpenBurnBar-HermesRelay-KeyWrap-v1|"+aad, length=32)`, AES-GCM seal, prepend ephemeral X9.63 pubkey → base64.
   - `unwrap_symmetric_key(wrapped_b64: str, private_key: RelayPrivateKey, aad: bytes) -> bytes` (envelope `>65` guard, `from_encoded_point` on `[:65]`, open `[65:]`).
   - Errors: `RelayCryptoError` + `InvalidPublicKey`/`InvalidCiphertext`/`InvalidSymmetricKey`/`RelayCryptoUnavailable`.
   - The key-wrap `salt=b""`, `info` prefix, AAD strings, and 65/12/16 byte layout are **hard invariants** — copy the constants verbatim from `HermesRelayCrypto.swift:62,82,178,182`. (I verified this exact code path round-trips in Python.)
   - Make `namespace` a parameter so the same module serves both `OpenBurnBar-HermesRelay-v1` and `OpenBurnBar-PiAgentRelay-v1` (Swift `PiAgentRelayCrypto:315-322`) without duplication.

2. **Add an agent-keystore helper in the same module:** `class AgentRelayIdentity` with `load_or_create(env_key="BURNBAR_RELAY_PRIVATE_KEY") -> RelayPrivateKey`. Persist the raw private key base64 via `hermes_cli.config.save_env_value_secure` (config.py:5289) to `~/.hermes/.env`, read via `get_env_value` (config.py:5321) — same store as `BURNBAR_ACCESS_TOKEN`. Expose `.public_key_base64()` for the pairing publish. Keep it env-driven so the keystore stays adapter-agnostic.

3. **Bump the gateway dep:** add `cryptography==46.0.7` to the exact-pinned `dependencies` in `/Users/albertonunez/.hermes/hermes-agent/pyproject.toml` and regenerate `uv.lock` (the repo rule at pyproject.toml top mandates exact pins + `uv lock`). State this explicitly in PR2 — without it the E2E path is a silent `RelayCryptoUnavailable`.

### B. Adapter changes (BurnBar repo, canonical) — `tools/hermes-platform-burnbar/adapter.py`

4. **Import the module and hold an identity.** At top, `from gateway.platforms.relay_crypto import AgentRelayIdentity, RelayPrivateKey, ... , RelayCryptoUnavailable` inside the same `try/except` guard style as httpx. In `BurnBarAdapter.__init__` (currently `:303-318`), add `self._relay_identity = AgentRelayIdentity.load_or_create()` and `self._peer_public_keys: Dict[str, str] = {}` (per-destination/thread phone pubkey cache).

5. **Pairing publish (handshake) — `interactive_setup()` `:825-859`.** Generate/load the relay identity and add `"devicePublicKey": identity.public_key_base64()` and `"relayEncryption": ALGORITHM`, `"relayKeyVersion": 1` to the `/device/start` payload (`:826-830`). Also bump the local handshake marker `"schemaVersion": HERMES_GATEWAY_SCHEMA_VERSION + 1` field the adapter sends so the server records this client as E2E-capable. (Server-side storage of `agentPublicKey` on `HermesGatewayClientDoc` is the companion-PR's job — `legacy.ts:592` + `approveHermesGatewayDeviceGrant` `hermesGateway.ts:927-940`; my brief only specifies the adapter sends it.)

6. **Seal outgoing text — `_post_message` `:215-238` (and `_post_confirm_followup` `:575-590`).** Before POSTing, if the destination has a known phone pubkey (E2E paired), replace plaintext `"text"` with the relay envelope:
   - `sym = os.urandom(32)`; `aad = relay_crypto.request_aad(uid_or_clientId, destinationId, messageId)`.
   - `payloadCiphertext = seal_to_base64(text.encode(), sym, aad)`; `wrappedKey = wrap_symmetric_key(sym, peer_pubkey_b64, key_aad(...))`.
   - Send `{"destinationId", "threadId", "replyToEventId", "payloadCiphertext", "wrappedKey", "relayEncryption": ALGORITHM, "relayKeyVersion": 1, "attachmentIds"}` and **omit plaintext `text`** (mirrors iOS `HermesService.swift:3872-3882`). Server `handleMessageSend` (`hermesGateway.ts:473-501`) stores these opaque fields instead of `text`.

7. **Open incoming events — `_handle_burnbar_event` `:389-422`.** Replace the plaintext read at `:395` (`raw.get("text")`). When `raw.get("relayEncryption")==ALGORITHM`:
   - record/cache the phone's pubkey from the event (`raw.get("senderPublicKey")` — companion PR puts it there) into `self._peer_public_keys[destinationId]`;
   - `sym = unwrap_symmetric_key(raw["wrappedKey"], self._relay_identity, key_aad(uid, destinationId, eventId))`;
   - `text = open_base64(raw["payloadCiphertext"], sym, request_aad(uid, destinationId, eventId)).decode()`.
   Decrypt `senderDisplayName` the same way if sealed (`:405`). Keep `model_switch` handling (`:390-393`) on the plaintext `modelId` (non-secret).

8. **Seal attachments — `_init_attachment` `:140-172` + `_upload_attachment` `:175-184`.** Seal the **filename** and the **bytes** to the phone pubkey before they leave the process:
   - In `_init_attachment`, send `"sealedFileName"` (relay envelope of `file_path.name`) instead of `"fileName"`, plus `"relayEncryption": ALGORITHM`. Send `"byteCount"` of the **sealed** payload.
   - In `_upload_attachment`, seal the file bytes: per-attachment `sym`, `aad = chunk_aad(uid, destinationId, attachmentId, 0, "attachment")`, upload `wrap_symmetric_key(sym,…) ‖ seal_to_base64(data, sym, aad)` as the object body, and POST the `wrappedKey` in the init/finalize call so the phone can open it. (Server only hashes bytes for integrity — `hermesGateway.ts:634` — so sealed bytes pass through unchanged.)

9. **Back-compat / refuse plaintext once E2E-paired (HARD rule).**
   - The adapter learns it is E2E-paired when `/device/poll`→approved returns `e2eEnabled: true` (companion PR) or when `interactive_setup` successfully published a `devicePublicKey`. Persist `BURNBAR_RELAY_E2E=1`.
   - When E2E is on: **never** send plaintext `text`/`fileName` and **never** accept a plaintext inbound `text` — if an event arrives without `relayEncryption`, drop it and surface `SendResult(success=False, error="peer is on a legacy non-E2E build; upgrade BurnBar to exchange messages")` (clear, actionable). Symmetric for sends: refuse and return that error rather than silently downgrading.
   - When E2E is off (legacy server that doesn't return a phone pubkey): fall back to today's plaintext path **only if** the server reports no E2E capability, so old adapters keep working during rollout. This is the only allowed plaintext path and must be gated behind the absence of a peer pubkey.
   - Schema handshake: bump the adapter's advertised `HERMES_GATEWAY_SCHEMA_VERSION` awareness to send `clientSchemaVersion: 2` (E2E-aware); the server keys plaintext-vs-sealed acceptance off it.

### C. README / docs update — `tools/hermes-platform-burnbar/README.md`

10. Add a top "**End-to-end encryption**" section: *"Messages and files exchanged with the agent are end-to-end encrypted (ECDH P-256 + HKDF-SHA256 + AES-256-GCM, `p256-hkdf-sha256-aesgcm`). BurnBar Cloud stores only ciphertext and a wrapped key it cannot open; only your paired phone and this agent hold keys."* Then the **5-line integration** any platform copies:
    ```python
    from gateway.platforms.relay_crypto import AgentRelayIdentity, request_aad, key_aad, seal_to_base64, wrap_symmetric_key
    identity = AgentRelayIdentity.load_or_create()          # at setup: publish identity.public_key_base64()
    sym = os.urandom(32)
    payloadCiphertext = seal_to_base64(text.encode(), sym, request_aad(uid, dest, msg_id))
    wrappedKey = wrap_symmetric_key(sym, peer_pubkey_b64, key_aad(uid, dest, msg_id))
    ```
    Document the new env vars `BURNBAR_RELAY_PRIVATE_KEY` (auto-managed), `BURNBAR_RELAY_E2E`, and that legacy peers produce a clear "upgrade BurnBar" error. Mirror the same prose into the fork `plugins/platforms/burnbar/README.md` (it is the copied mirror).

### D. Tests proving round-trip

11. **`smoke_local.py` (`tools/hermes-platform-burnbar/smoke_local.py`):**
    - Extend `install_plugin` (`:194-199`) to also copy the new module location, OR (preferred) copy `gateway/platforms/relay_crypto.py` is already in the checkout — instead add a step that imports it. Add a phone-side keypair in `FakeBurnBarState`: generate a P-256 keypair with `cryptography`, expose its pubkey via `/destinations` or the approved-grant, and **seal** enqueued events to the agent's published `devicePublicKey`.
    - In `FakeBurnBarState.enqueue` (`:44-67`), produce `payloadCiphertext`/`wrappedKey`/`relayEncryption` instead of plaintext `text`, sealing with the fake phone key to the agent pubkey the adapter published at connect.
    - In `do_POST /v1/hermes-gateway/messages` (`:149-151`) and `/attachments/init` (`:161-172`), capture `payloadCiphertext`/`wrappedKey`/`sealedFileName`, and in `run_smoke` (`:217-302`) **open them with the fake phone private key** and assert the recovered plaintext equals the agent's reply / artifact body / filename. Assert the raw HTTP body contains **no** plaintext (negative test): `assert "adapter reply" not in json.dumps(state.messages)`.
    - Add an explicit `test_relay_crypto_round_trip` calling the module directly: phone-wrap → agent-unwrap → agent-seal → phone-open, asserting equality, plus a cross-direction key-wrap test (the byte layout I verified: 65+12+ct+16).

12. **`tests/gateway/test_burnbar_plugin.py` (fork):** add (a) `test_relay_crypto_envelope_shape` asserting `wrap_symmetric_key` output decodes to `len==65 + 12 + plaintext + 16` and `from_encoded_point` accepts `[:65]`; (b) `test_adapter_seals_outbound_when_paired` — monkeypatch a peer pubkey, call `_post_message`, assert the JSON has `payloadCiphertext`/`wrappedKey` and **no** `text`; (c) `test_adapter_opens_inbound_event` — feed a sealed event built with a test phone key, assert `MessageEvent.text` decrypts; (d) `test_refuses_plaintext_when_e2e` — sealed-off inbound while `BURNBAR_RELAY_E2E=1` returns the "upgrade BurnBar" error. Add a Swift↔Python interop fixture: drop a base64 envelope produced by `HermesRelayCryptoTests` (Swift) into the test and assert Python `open_base64`/`unwrap_symmetric_key` recovers it (and vice-versa) — this is the cross-language gate equivalent to `apps/console/test/interop.test.ts`.

### E. Cross-PR contract notes (so the companion BurnBar-repo PR lines up)

13. The companion server/iOS PR owns: adding `agentPublicKey` to `HermesGatewayClientDoc` (`legacy.ts:592-610`) set in `approveHermesGatewayDeviceGrant` (`hermesGateway.ts:927-940`) and `handleDeviceStart` (`:346-357`); accepting `payloadCiphertext`/`wrappedKey`/`relayEncryption` in `handleMessageSend` (`:486-498`) and `handleAttachmentInit` (`:611-640`) in place of `text`/`fileName`; emitting `senderPublicKey` + sealed event fields in `enqueueHermesGatewayEvent`/`serializeHermesGatewayEvent` (`:1100-1185`, `hermesGateway.ts:294-325`); iOS sealing events to `agentPublicKey` and opening agent replies (mirror `HermesService.swift:3872-3882`); `firestore.rules:1955-1989` `hasOnly` allowlists swapping plaintext keys for the sealed/wrapped keys; and registry honesty flip (`packages/data-domains/registry.json:116` from server-readable → E2E for gateway). My slice's wire format (AAD strings, byte layout, field names `payloadCiphertext`/`wrappedKey`/`relayEncryption`/`relayKeyVersion`) is the fixed contract both sides bind to — taken verbatim from `HermesRelayCrypto.swift` and `HermesService.swift:3872-3882`, not reinvented.

**Files I will change (absolute paths):**
- NEW `/Users/albertonunez/.hermes/hermes-agent/gateway/platforms/relay_crypto.py` (reusable module + keystore)
- `/Users/albertonunez/.hermes/hermes-agent/pyproject.toml` (+`cryptography==46.0.7`, `uv.lock`)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/tools/hermes-platform-burnbar/adapter.py` (`__init__` :303-318, `interactive_setup` :825-859, `_post_message` :215-238, `_post_confirm_followup` :575-590, `_handle_burnbar_event` :389-422, `_init_attachment` :140-172, `_upload_attachment` :175-184)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/tools/hermes-platform-burnbar/README.md` (+ fork mirror `plugins/platforms/burnbar/README.md`)
- `/Users/albertonunez/Documents/Windsurf/BurnBar/tools/hermes-platform-burnbar/smoke_local.py` (`install_plugin` :194-199, `FakeBurnBarState.enqueue` :44-67, `do_POST` :149-172, `run_smoke` :217-302)
- `/Users/albertonunez/.hermes/hermes-agent/tests/gateway/test_burnbar_plugin.py` (new E2E + interop tests)