All complete. Everything is byte-exact, tested, and within ownership.

## CHANGELOG

**`gateway/crypto/__init__.py`** (NEW, fork `/Users/albertonunez/.hermes/hermes-agent/gateway/crypto/__init__.py`)
- New package init re-exporting the public relay-e2ee API. Exported symbols: `ALGORITHM`, `KEY_VERSION`, `HERMES_NAMESPACE`, `PIAGENT_NAMESPACE`, `RelayNamespace`, `RelayPrivateKey`, `AgentRelayIdentity`, `RelayCryptoError`, `InvalidPublicKeyError`, `InvalidCiphertextError`, `InvalidSymmetricKeyError`, `generate_private_key`, `generate_symmetric_key`, `seal_to_base64`, `open_base64`, `wrap_symmetric_key`, `unwrap_symmetric_key`, `request_aad`, `key_aad`, `chunk_aad`. (`gateway`/`gateway.*` already covered by `[tool.setuptools.packages.find]`, so the new sub-package ships in the wheel.)

**`gateway/crypto/relay_e2ee.py`** (NEW)
- Byte-exact Python mirror of Swift `HermesRelayCrypto` (and `PiAgentRelayCrypto`). Constants `ALGORITHM="p256-hkdf-sha256-aesgcm"`, `KEY_VERSION=1`, `HERMES_NAMESPACE="OpenBurnBar-HermesRelay"`, `PIAGENT_NAMESPACE="OpenBurnBar-PiAgentRelay"`, `RELAY_PRIVATE_KEY_ENV="BURNBAR_RELAY_PRIVATE_KEY"`.
- `RelayNamespace` dataclass parameterizes the AAD prefix (`<name>-v1`) and key-wrap info prefix (`<name>-KeyWrap-v1|`) so the same code serves Hermes and PiAgent; every AAD/wrap function takes `namespace=` (default Hermes).
- AAD builders `request_aad`/`key_aad`/`chunk_aad` produce `"<ns>-v1|" + "|".join(parts)` UTF-8 (`chunk` renders sequence via `str(int)`).
- `RelayPrivateKey` (frozen dataclass over raw 32B scalar): `.from_raw`, `.from_base64`, `.raw_representation`, `.raw_base64()`, `.public_key_x963()`, `.public_key_base64()`. Imports the scalar via `ec.derive_private_key(int.from_bytes(raw,'big'), SECP256R1())` (the #1 interop trap), pubkey via `Encoding.X962, PublicFormat.UncompressedPoint`.
- `generate_private_key()`, `generate_symmetric_key()` (32B).
- `seal_to_base64`/`open_base64`: AES-256-GCM, 12B nonce, combined `base64(nonce‖ct‖tag)`.
- `wrap_symmetric_key`/`unwrap_symmetric_key`: ephemeral P-256 ECDH → HKDF-SHA256 (`salt=b"\x00"*32`, `info=key_wrap_prefix+aad`, 32B) → AES-256-GCM; wrapped wire = `base64(ephPubX963(65)‖nonce(12)‖ct(32)‖tag(16))` = 125B. `unwrap` accepts a `RelayPrivateKey` or raw 32B scalar; uses `keyAAD`.
- `AgentRelayIdentity` + `AgentRelayIdentity.load_or_create(env_var=..., environ=..., persist=...)`: loads base64 scalar from `BURNBAR_RELAY_PRIVATE_KEY`, mints+optionally-persists a fresh key when missing/corrupt; exposes `public_key_base64`, `key_version`, `algorithm` for `device/start`/`handleRuntimeStatus` publishing.
- Typed errors `RelayCryptoError`/`InvalidPublicKeyError`/`InvalidCiphertextError`/`InvalidSymmetricKeyError` (mirror `HermesRelayCryptoError`). `cryptography` imported lazily inside each function (mirrors `qqbot/crypto.py`, `wecom_crypto.py`) — verified module import does not load cryptography.

**`tests/gateway/fixtures/HermesRelayWireVector.json`** (NEW) — vendored verbatim (`cmp`-identical) from `OpenBurnBarCore/Tests/OpenBurnBarCoreTests/Fixtures/HermesRelayWireVector.json`, revision `v1`.

**`tests/gateway/test_relay_e2ee.py`** (NEW) — 23 tests, all passing via `.venv/bin/python -m pytest`. Coverage: fixture revision/algorithm contract; AAD byte-match vs fixture (`requestAAD`/`keyAAD`/`chunkAAD`) + PiAgent prefix swap; Python opens Swift `wrappedKey`→`symmetricKey` (via `RelayPrivateKey` and raw bytes), `payloadCiphertext`→`encodedPlaintext`/JSON, `chunkCiphertext`→`chunkPlaintext`; derived pubkey matches `recipientPublicKey`; Python reseal round-trip with unwrapped Swift key; Python wrap→unwrap asserting 125B/`0x04`; 44B combined shape for 16B plaintext; adversarial wrong-AAD `InvalidTag` (payload + wrap), wrong-key `InvalidTag`, two-wraps-distinct-but-both-unwrap; short-key/short-envelope/invalid-pubkey typed errors; `AgentRelayIdentity` load/create/persist/corrupt-env. Uses `pytest.importorskip("cryptography")`; reads fixture via `Path(__file__).../fixtures/` (no `sys.path` insertion → passes the conftest anti-pattern guard).

**`pyproject.toml`** (MODIFIED) — added optional extra `gateway-e2ee = ["cryptography>=46"]` (range, not exact pin, with a rationale comment that the core `dependencies` exact-pin policy intentionally does not extend to opt-in extras).

**`uv.lock`** (REGENERATED via `uv lock`, exit 0) — added the `gateway-e2ee` extra → `{ name = "cryptography", marker = "extra == 'gateway-e2ee'", specifier = ">=46" }` and `provides-extras` entry. `cryptography==46.0.7` was already resolved transitively (alibabacloud/azure deps), so no new package download and zero version churn — only the extra mapping was added.

Deviations / notes:
- CONTRACT path `gateway/crypto/relay_e2ee.py` was used (authoritative), not the recon brief's earlier `gateway/platforms/relay_crypto.py` suggestion. Test file named `test_relay_e2ee.py` to match the module, per CONTRACT §STREAM OWNERSHIP.
- I ran the actual pytest (not just `py_compile`) since this is a Python-only stream and byte-exact interop can only be proven by opening the Swift vector — 23/23 pass.
- Pre-existing working-tree edits to `gateway/platforms/api_server.py` and `plugins/platforms/burnbar/adapter.py` are NOT mine (they were already modified before this slice; adapter sealing/api_server removal are F-adapter/orchestrator concerns) — I left them untouched.

Cross-stream dependency: F-adapter must import `from gateway.crypto.relay_e2ee import ...` (or call `AgentRelayIdentity.load_or_create`) to seal `text`/attachment bodies and unwrap inbound events; the recipient `agentRelayPublicKey`/`relayPublicKey` pairing fields are supplied by B-fn-gw + B-ios-gw per GATEWAY WIRE CONTRACT.