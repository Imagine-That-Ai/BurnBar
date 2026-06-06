"""E2EE and hostile-path tests for the BurnBar Cloud platform plugin."""

from __future__ import annotations

import json
import logging
import os

import pytest

from gateway.config import PlatformConfig
from tests.gateway._plugin_adapter_loader import load_plugin_adapter

_burnbar = load_plugin_adapter("burnbar")

BurnBarAdapter = _burnbar.BurnBarAdapter

try:
    from plugins.platforms.burnbar import relay_e2ee

    RELAY_CRYPTO_AVAILABLE = True
except ImportError:  # pragma: no cover - cryptography missing in CI slice.
    relay_e2ee = None
    RELAY_CRYPTO_AVAILABLE = False

requires_relay = pytest.mark.skipif(
    not RELAY_CRYPTO_AVAILABLE, reason="cryptography / relay_e2ee unavailable"
)


class _FakeResponse:
    def __init__(self, json_body=None, status_code=200, content=b"{}"):
        self._json = json_body if json_body is not None else {}
        self.status_code = status_code
        self.content = content

    def raise_for_status(self):
        if self.status_code >= 400:
            raise RuntimeError(f"HTTP {self.status_code}")

    def json(self):
        return self._json


class _RecordingClient:
    def __init__(self, *, post_responses=None, put_response=None, get_responses=None):
        self.post_responses = post_responses or {}
        self.put_response = put_response or _FakeResponse()
        self.get_responses = get_responses or {}
        self.posts = []
        self.puts = []
        self.gets = []

    def _match(self, mapping, url):
        for suffix, value in mapping.items():
            if url.endswith(suffix):
                return value
        return None

    async def post(self, url, headers=None, json=None):
        self.posts.append((url, json))
        match = self._match(self.post_responses, url)
        if callable(match):
            return match(json)
        if match is not None:
            return match
        return _FakeResponse({})

    async def put(self, url, content=None, headers=None):
        self.puts.append((url, content, headers))
        return self.put_response

    async def get(self, url, headers=None, params=None):
        self.gets.append((url, params))
        match = self._match(self.get_responses, url)
        if callable(match):
            return match(params)
        if match is not None:
            return match
        return _FakeResponse({})

    async def aclose(self):
        return None


async def _noop():
    return None


def _legacy_adapter(monkeypatch, tmp_path):
    monkeypatch.setattr(_burnbar, "CURSOR_FILE", tmp_path / "cursor.json")
    monkeypatch.setattr(_burnbar, "REPLAY_LEDGER_FILE", tmp_path / "replay.json")
    monkeypatch.delenv("BURNBAR_RELAY_E2E", raising=False)
    cfg = PlatformConfig(enabled=True, extra={"access_token": "tok", "home_channel": "burnbar:home"})
    return BurnBarAdapter(cfg)


# ---------------------------------------------------------------------------
# E2E relay (PR2): seal -> open round trip, refuse-plaintext
# ---------------------------------------------------------------------------
def _e2e_adapter(monkeypatch, tmp_path, *, peer_public_key=None):
    """Build an adapter forced into E2E mode with an injected agent identity."""
    monkeypatch.setattr(_burnbar, "CURSOR_FILE", tmp_path / "cursor.json")
    monkeypatch.setattr(_burnbar, "REPLAY_LEDGER_FILE", tmp_path / "replay.json")
    monkeypatch.delenv("BURNBAR_RELAY_E2E", raising=False)
    monkeypatch.delenv("BURNBAR_RELAY_PEER_PUBLIC_KEY", raising=False)
    cfg = PlatformConfig(enabled=True, extra={"access_token": "tok", "home_channel": "burnbar:home"})
    adapter = BurnBarAdapter(cfg)
    # Inject a deterministic agent relay identity without touching real user config.
    agent_priv = relay_e2ee.generate_private_key()
    adapter._relay_identity = relay_e2ee.AgentRelayIdentity(agent_priv)
    adapter._relay_e2e_enabled = True
    adapter._relay_uid = "uid-1"
    adapter._relay_client_id = "client-1"
    adapter._relay_uid_pinned = True
    adapter._relay_client_id_pinned = True
    adapter._relay_e2e_config_error = None
    if peer_public_key:
        adapter._peer_public_key = peer_public_key
    adapter._load_replay_ledger(reset=True)
    return adapter, agent_priv


def _phone_sealed_event(adapter, phone_private, event_id, payload):
    """Build a phone->agent sealed event using the gateway event AAD contract."""
    phone_public = phone_private.public_key_base64()
    agent_public = adapter._relay_public_key_base64()
    body = {"destinationId": "burnbar:home"}
    body.update(payload)
    sym = relay_e2ee.generate_symmetric_key()
    payload_ct = relay_e2ee.seal_to_base64(
        json.dumps(body).encode(),
        sym,
        _burnbar._gateway_event_aad("uid-1", "client-1", event_id),
    )
    wrapped = relay_e2ee.wrap_symmetric_key(
        sym,
        agent_public,
        _burnbar._gateway_event_key_aad("uid-1", "client-1", event_id),
        sender_private=phone_private,
    )
    return {
        "id": event_id,
        "destinationId": "burnbar:home",
        "senderPublicKey": phone_public,
        "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
        "relayEnvelope": {
            "eventId": event_id,
            "payloadCiphertext": payload_ct,
            "wrappedKey": wrapped,
            "senderPublicKey": phone_public,
            "relayEncryption": _burnbar.RELAY_ENCRYPTION,
            "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
        },
    }


@requires_relay
def test_agent_relay_public_key_is_x963_65_bytes(monkeypatch, tmp_path):
    import base64

    adapter, agent_priv = _e2e_adapter(monkeypatch, tmp_path)
    pub_b64 = adapter._relay_public_key_base64()
    raw = base64.b64decode(pub_b64)
    assert len(raw) == 65 and raw[0] == 0x04  # X9.63 uncompressed P-256


@requires_relay
@pytest.mark.asyncio
async def test_seal_send_then_phone_opens(monkeypatch, tmp_path):
    """Agent seals its reply to the phone pubkey; the phone opens it."""
    phone_priv = relay_e2ee.generate_private_key()
    adapter, _agent = _e2e_adapter(
        monkeypatch, tmp_path, peer_public_key=phone_priv.public_key_base64()
    )
    client = _RecordingClient(post_responses={"/messages": _FakeResponse({"message": {"id": "m1"}})})
    adapter._client = client

    result = await adapter.send("burnbar:home", "secret reply")
    assert result.success is True

    _, body = client.posts[-1]
    # Plaintext is GONE; only the sealed envelope remains.
    assert "text" not in body
    env = body["relayEnvelope"]
    assert env["relayEncryption"] == _burnbar.RELAY_ENCRYPTION
    # v2 authenticated wrap: gateway envelopes stamp the gateway wrap version and
    # carry the agent's OWN relay public key as the authenticated sender.
    assert env["relayKeyVersion"] == _burnbar.GATEWAY_RELAY_KEY_VERSION
    assert env["senderPublicKey"] == _agent.public_key_base64()
    assert body["relayEncryption"] == _burnbar.RELAY_ENCRYPTION
    # The agent echoes the AAD-bound messageId at the top level so the server
    # adopts it byte-for-byte; otherwise the phone rebuilds the AAD from a different
    # server id and every sealed reply fails AEAD.
    assert body["messageId"] == env["messageId"]

    # The phone unwraps the key (binding the agent's pinned sender key) with the
    # shared wire key AAD, then opens the payload with the payload AAD.
    message_id = env["messageId"]
    payload_aad = _burnbar._gateway_message_aad("uid-1", "client-1", message_id)
    key_aad = _burnbar._gateway_message_key_aad("uid-1", "client-1", message_id)
    sym = relay_e2ee.unwrap_symmetric_key(
        env["wrappedKey"], phone_priv, key_aad, sender_public_base64=env["senderPublicKey"]
    )
    opened = json.loads(relay_e2ee.open_base64(env["payloadCiphertext"], sym, payload_aad).decode())
    assert opened == {"text": "secret reply", "destinationId": "burnbar:home"}


@requires_relay
@pytest.mark.asyncio
async def test_phone_sealed_event_is_opened_by_agent(monkeypatch, tmp_path):
    """Phone seals an event to the agent pubkey; the adapter opens it (v2, pinned sender)."""
    phone_priv = relay_e2ee.generate_private_key()
    phone_pub = phone_priv.public_key_base64()
    adapter, agent_priv = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=phone_pub)
    agent_pub = adapter._relay_public_key_base64()

    # Phone-side v2 seal (mirrors iOS): wrap to the agent pubkey binding the phone's
    # static key as the authenticated sender. Sender identity rides inside the sealed
    # payload, never trusted from relay-controlled top-level metadata.
    event_id = "evt_sealed_1"
    payload_aad = _burnbar._gateway_event_aad("uid-1", "client-1", event_id)
    key_aad = _burnbar._gateway_event_key_aad("uid-1", "client-1", event_id)
    sym = relay_e2ee.generate_symmetric_key()
    payload = json.dumps(
        {
            "text": "open me",
            "destinationId": "burnbar:home",
            "senderId": "phone-user",
            "senderDisplayName": "Phone",
            "threadId": "t1",
            "replayCounter": 1,
        }
    ).encode()
    payload_ct = relay_e2ee.seal_to_base64(payload, sym, payload_aad)
    wrapped = relay_e2ee.wrap_symmetric_key(sym, agent_pub, key_aad, sender_private=phone_priv)

    received = []

    async def capture(event):
        received.append(event)

    adapter.handle_message = capture
    await adapter._handle_burnbar_event(
        {
            "id": event_id,
            "destinationId": "burnbar:home",
            "senderId": "RELAY-SPOOFED",  # ignored in favor of the sealed senderId
            "senderDisplayName": "RELAY-SPOOFED",
            "senderPublicKey": phone_pub,
            "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
            "relayEnvelope": {
                "payloadCiphertext": payload_ct,
                "wrappedKey": wrapped,
                "senderPublicKey": phone_pub,
                "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
            },
        }
    )

    assert len(received) == 1
    assert received[0].text == "open me"
    # Identity is taken from the SEALED payload, never the relay-spoofed top level.
    assert received[0].source.user_name == "Phone"
    assert received[0].source.user_id == "phone-user"
    assert received[0].source.thread_id == "t1"


@requires_relay
@pytest.mark.asyncio
async def test_refuses_plaintext_event_when_e2e_paired(monkeypatch, tmp_path):
    """A legacy plaintext event arriving on an E2E link is dropped, not leaked."""
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path)
    received = []

    async def capture(event):
        received.append(event)

    adapter.handle_message = capture
    await adapter._handle_burnbar_event(
        {"id": "evt_plain", "destinationId": "burnbar:home", "text": "plaintext sneaking in"}
    )
    # Dropped: never surfaced to Hermes.
    assert received == []


@requires_relay
@pytest.mark.asyncio
async def test_refuses_send_when_e2e_but_no_peer_key(monkeypatch, tmp_path):
    """When E2E is on but we hold no phone pubkey, send refuses with a clear error."""
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path)  # no peer key
    adapter._peer_public_key = None
    adapter._client = _RecordingClient()

    result = await adapter.send("burnbar:home", "would-be-plaintext")
    assert result.success is False
    assert "upgrade BurnBar" in (result.error or "")
    # Nothing was posted.
    assert all(not u.endswith("/messages") for (u, _b) in adapter._client.posts)


@requires_relay
@pytest.mark.asyncio
async def test_seal_attachment_round_trip(monkeypatch, tmp_path):
    """Attachment bytes + filename are sealed; the phone opens both."""
    phone_priv = relay_e2ee.generate_private_key()
    adapter, _agent = _e2e_adapter(
        monkeypatch, tmp_path, peer_public_key=phone_priv.public_key_base64()
    )
    f = tmp_path / "diagram.png"
    f.write_bytes(b"\x89PNG-binary-body")

    def _init_attachment_response(*args):
        body = args[-1] if args else {}
        env = body.get("relayEnvelope") or {}
        adopted_id = body.get("attachmentId") or env.get("attachmentId") or "att_e2e"
        return _FakeResponse(
            {"attachment": {"id": adopted_id}, "uploadURL": "https://signed.example/put"}
        )

    client = _RecordingClient(
        post_responses={
            "/attachments/init": _init_attachment_response,
            "/messages": _FakeResponse({"message": {"id": "m_att"}}),
        }
    )
    adapter._client = client

    result = await adapter.send_document("burnbar:home", str(f), caption="")
    assert result.success is True

    # init carried a sealed envelope, not a plaintext fileName.
    _, init_body = next((u, b) for (u, b) in client.posts if u.endswith("/attachments/init"))
    assert "fileName" not in init_body
    env = init_body["relayEnvelope"]
    attachment_id = env["attachmentId"]
    # v2 authenticated wrap + attachment id round-trip: the agent echoes attachmentId at the
    # top level so the server adopts it and the phone's AAD matches (else AEAD fails).
    assert env["relayKeyVersion"] == _burnbar.GATEWAY_RELAY_KEY_VERSION
    assert env["senderPublicKey"] == _agent.public_key_base64()
    assert init_body["attachmentId"] == attachment_id

    # Uploaded body is ciphertext (not the raw PNG bytes).
    upload_url, uploaded, _hdrs = client.puts[0]
    assert uploaded != b"\x89PNG-binary-body"

    # Phone unwraps the body key (binding the agent's pinned sender key) with the
    # attachment-KEY AAD, then opens the manifest (payloadCiphertext) with the
    # manifest AAD and the body with the body AAD use distinct labels so the relay
    # cannot swap one slot for the other.
    key_aad = _burnbar._gateway_attachment_key_aad("uid-1", "client-1", attachment_id)
    manifest_aad = _burnbar._gateway_attachment_manifest_aad("uid-1", "client-1", attachment_id)
    body_aad = _burnbar._gateway_attachment_body_aad("uid-1", "client-1", attachment_id)
    assert manifest_aad != body_aad  # distinct slot binding
    body_key = relay_e2ee.unwrap_symmetric_key(
        env["wrappedKey"], phone_priv, key_aad, sender_public_base64=env["senderPublicKey"]
    )
    manifest = json.loads(relay_e2ee.open_base64(env["payloadCiphertext"], body_key, manifest_aad).decode())
    assert manifest["fileName"] == "diagram.png"
    assert manifest["byteCount"] == len(b"\x89PNG-binary-body")
    assert manifest["destinationId"] == "burnbar:home"
    opened_body = relay_e2ee.open_base64(uploaded.decode("ascii"), body_key, body_aad)
    assert opened_body == b"\x89PNG-binary-body"

    # A relay that swaps the manifest ciphertext into the body slot (or vice-
    # versa) is rejected: the AAD label mismatch fails the GCM tag.
    from cryptography.exceptions import InvalidTag

    with pytest.raises(InvalidTag):
        relay_e2ee.open_base64(env["payloadCiphertext"], body_key, body_aad)
    with pytest.raises(InvalidTag):
        relay_e2ee.open_base64(uploaded.decode("ascii"), body_key, manifest_aad)


@requires_relay
def test_gateway_aad_is_locked_wire_prefix():
    """The gateway AAD bytes match the locked wire prefix verbatim."""
    assert _burnbar._gateway_event_aad("u", "c", "e") == b"OpenBurnBar-HermesRelay-v1|gatewayEvent|u|c|e"
    assert _burnbar._gateway_event_key_aad("u", "c", "e") == b"OpenBurnBar-HermesRelay-v1|gatewayEventKey|u|c|e"
    assert _burnbar._gateway_message_aad("u", "c", "m") == b"OpenBurnBar-HermesRelay-v1|gatewayMessage|u|c|m"
    assert _burnbar._gateway_message_key_aad("u", "c", "m") == b"OpenBurnBar-HermesRelay-v1|gatewayMessageKey|u|c|m"
    assert (
        _burnbar._gateway_attachment_manifest_aad("u", "c", "a")
        == b"OpenBurnBar-HermesRelay-v1|gatewayAttachmentManifest|u|c|a"
    )
    assert (
        _burnbar._gateway_attachment_body_aad("u", "c", "a")
        == b"OpenBurnBar-HermesRelay-v1|gatewayAttachmentBody|u|c|a"
    )
    assert (
        _burnbar._gateway_attachment_key_aad("u", "c", "a")
        == b"OpenBurnBar-HermesRelay-v1|gatewayAttachmentKey|u|c|a"
    )
    # Manifest vs body vs key vs event/message payload/key use distinct labels (anti-swap).
    labels = {
        _burnbar._gateway_event_aad("u", "c", "a"),
        _burnbar._gateway_event_key_aad("u", "c", "a"),
        _burnbar._gateway_message_aad("u", "c", "a"),
        _burnbar._gateway_message_key_aad("u", "c", "a"),
        _burnbar._gateway_attachment_manifest_aad("u", "c", "a"),
        _burnbar._gateway_attachment_body_aad("u", "c", "a"),
        _burnbar._gateway_attachment_key_aad("u", "c", "a"),
    }
    assert len(labels) == 7


# ---------------------------------------------------------------------------
# Relay E2E hardening coverage: peer-key pinning, fail-closed behavior,
# standalone sealing, persistence, replay, attachment AAD, and model switches.
# ---------------------------------------------------------------------------
def _no_persist(monkeypatch):
    """Stop _pin_peer_public_key from writing real user config in tests."""
    import hermes_cli.config as _cfg

    monkeypatch.setattr(_cfg, "save_env_value", lambda *a, **k: None, raising=False)


# --- Peer-key pinning: TOFU plus post-pairing change rejection ---------------
@requires_relay
def test_peer_key_pins_once_then_rejects_a_changed_key(monkeypatch, tmp_path):
    """TOFU: first peer key is pinned; a *different* later key is refused (MITM)."""
    _no_persist(monkeypatch)
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path)  # no peer pinned yet
    assert adapter._peer_public_key is None

    first = relay_e2ee.generate_private_key().public_key_base64()
    second = relay_e2ee.generate_private_key().public_key_base64()

    # First key wins only when the authenticated pairing path opts in explicitly.
    assert (
        adapter._pin_peer_public_key(
            "burnbar:home", first, source="pairing", allow_new_pin=True
        )
        is True
    )
    assert adapter._peer_public_key == first

    # A different key arriving afterwards is rejected and does not overwrite.
    assert adapter._pin_peer_public_key("burnbar:home", second, source="event") is False
    assert adapter._peer_public_key == first  # still the pinned key

    # The same key re-advertised is accepted (idempotent), key unchanged.
    assert adapter._pin_peer_public_key("burnbar:home", first, source="state") is True
    assert adapter._peer_public_key == first


@requires_relay
def test_absorb_relay_state_does_not_rotate_pinned_peer_key(monkeypatch, tmp_path):
    """A server /state doc cannot rotate the pinned peer key post-pairing."""
    _no_persist(monkeypatch)
    pinned = relay_e2ee.generate_private_key().public_key_base64()
    attacker = relay_e2ee.generate_private_key().public_key_base64()
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=pinned)

    adapter._absorb_relay_state({"relayPublicKey": attacker, "destinationId": "burnbar:home"})
    assert adapter._peer_public_key == pinned  # untrusted relay cannot rotate it


@requires_relay
@pytest.mark.asyncio
async def test_event_with_substituted_sender_key_does_not_rotate_pin(monkeypatch, tmp_path):
    """A real v2 event whose wire senderPublicKey is tampered still opens via the
    pinned key (the static-static DH authenticates the sender), and the advisory
    wire field does not rotate the pin. The old v1 form passed for the wrong
    reason: it was dropped at the v2 gate, so 'Event opens' was never exercised."""
    _no_persist(monkeypatch)
    phone_priv = relay_e2ee.generate_private_key()
    pinned = phone_priv.public_key_base64()
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=pinned)
    agent_pub = adapter._relay_public_key_base64()

    event_id = "evt_sub_key"
    payload_aad = _burnbar._gateway_event_aad("uid-1", "client-1", event_id)
    key_aad = _burnbar._gateway_event_key_aad("uid-1", "client-1", event_id)
    sym = relay_e2ee.generate_symmetric_key()
    payload_ct = relay_e2ee.seal_to_base64(
        json.dumps({"text": "hi", "destinationId": "burnbar:home", "replayCounter": 1}).encode(),
        sym,
        payload_aad,
    )
    # Real v2 wrap: the PHONE is the authenticated sender (it holds the pinned key).
    wrapped = relay_e2ee.wrap_symmetric_key(sym, agent_pub, key_aad, sender_private=phone_priv)
    attacker_key = relay_e2ee.generate_private_key().public_key_base64()

    received = []

    async def capture(event):
        received.append(event)

    adapter.handle_message = capture
    await adapter._handle_burnbar_event(
        {
            "id": event_id,
            "destinationId": "burnbar:home",
            "senderPublicKey": attacker_key,  # adversarial wire field (advisory only)
            "relayEnvelope": {
                "payloadCiphertext": payload_ct,
                "wrappedKey": wrapped,
                "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
            },
        }
    )
    # The content opens via the pinned key, which exercises v2 authentication,
    assert len(received) == 1
    assert received[0].text == "hi"
    # and the substituted wire senderPublicKey does not rotate the pin.
    assert adapter._peer_public_key == pinned


# --- Fail-closed plaintext refusal and downgrade rejection -------------------
@requires_relay
@pytest.mark.asyncio
async def test_fail_closed_refuses_send_when_identity_cannot_load(monkeypatch, tmp_path):
    """E2E paired but the relay identity won't load: send refuses, never plaintext."""
    phone_priv = relay_e2ee.generate_private_key()
    adapter, _agent = _e2e_adapter(
        monkeypatch, tmp_path, peer_public_key=phone_priv.public_key_base64()
    )
    # Simulate a broken identity load: must_seal stays True, can_seal goes False.
    adapter._relay_identity = None
    monkeypatch.setattr(adapter, "_ensure_relay_identity", lambda: None)
    assert adapter._sealer.must_seal is True
    assert adapter._sealer.can_seal is False

    adapter._client = _RecordingClient(
        post_responses={"/messages": _FakeResponse({"message": {"id": "x"}})}
    )
    result = await adapter.send("burnbar:home", "must-not-leak")
    assert result.success is False
    assert all(not u.endswith("/messages") for (u, _b) in adapter._client.posts)


@requires_relay
@pytest.mark.asyncio
async def test_fail_closed_refuses_inbound_event_when_identity_cannot_load(monkeypatch, tmp_path):
    """E2E paired but identity won't load: a sealed inbound event is refused, not leaked."""
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path)
    monkeypatch.setattr(adapter, "_relay_private_key", lambda: None)
    received = []
    adapter.handle_message = lambda e: received.append(e) or _noop()
    await adapter._handle_burnbar_event(
        {
            "id": "evt_noid",
            "destinationId": "burnbar:home",
            "relayEnvelope": {"payloadCiphertext": "AAAA", "wrappedKey": "AAAA"},
        }
    )
    assert received == []  # refused, nothing surfaced to Hermes


# --- Standalone sends: seal or refuse on paired links ------------------------
@requires_relay
@pytest.mark.asyncio
async def test_standalone_send_seals_on_paired_link(monkeypatch, tmp_path):
    """_standalone_send seals to the pinned peer key on an E2E-paired link."""
    monkeypatch.setattr(_burnbar, "CURSOR_FILE", tmp_path / "cursor.json")
    phone_priv = relay_e2ee.generate_private_key()
    monkeypatch.setenv("BURNBAR_RELAY_E2E", "1")
    monkeypatch.setenv("BURNBAR_RELAY_PEER_PUBLIC_KEY", phone_priv.public_key_base64())
    monkeypatch.setenv("BURNBAR_RELAY_UID", "uid-s")
    monkeypatch.setenv("BURNBAR_RELAY_CLIENT_ID", "client-s")
    # Inject a deterministic agent identity so __init__ does not persist to disk.
    agent_priv = relay_e2ee.generate_private_key()
    monkeypatch.setattr(
        relay_e2ee.AgentRelayIdentity,
        "load_or_create",
        classmethod(lambda cls, **kw: relay_e2ee.AgentRelayIdentity(agent_priv)),
    )

    client = _RecordingClient(post_responses={"/messages": _FakeResponse({"message": {"id": "sm"}})})

    class _CM:
        async def __aenter__(self):
            return client

        async def __aexit__(self, *a):
            return False

    monkeypatch.setattr(_burnbar.httpx, "AsyncClient", lambda *a, **k: _CM())

    cfg = PlatformConfig(enabled=True, extra={"access_token": "tok", "home_channel": "burnbar:home"})
    out = await _burnbar._standalone_send(cfg, "burnbar:home", "standalone secret")
    assert out.get("success") is True
    _, body = next((u, b) for (u, b) in client.posts if u.endswith("/messages"))
    assert "text" not in body  # plaintext GONE
    env = body["relayEnvelope"]
    # The standalone path must also echo the AAD-bound messageId on the wire.
    assert body["messageId"] == env["messageId"]
    sym = relay_e2ee.unwrap_symmetric_key(
        env["wrappedKey"], phone_priv,
        _burnbar._gateway_message_key_aad("uid-s", "client-s", env["messageId"]),
        sender_public_base64=env["senderPublicKey"],
    )
    opened = json.loads(
        relay_e2ee.open_base64(
            env["payloadCiphertext"], sym,
            _burnbar._gateway_message_aad("uid-s", "client-s", env["messageId"]),
        ).decode()
    )
    assert opened == {"text": "standalone secret", "destinationId": "burnbar:home"}


@requires_relay
@pytest.mark.asyncio
async def test_standalone_send_refuses_when_paired_but_no_peer_key(monkeypatch, tmp_path):
    """E2E paired with no pinned peer key: standalone refuses, never sends plaintext."""
    monkeypatch.setattr(_burnbar, "CURSOR_FILE", tmp_path / "cursor.json")
    monkeypatch.setenv("BURNBAR_RELAY_E2E", "1")
    monkeypatch.delenv("BURNBAR_RELAY_PEER_PUBLIC_KEY", raising=False)
    agent_priv = relay_e2ee.generate_private_key()
    monkeypatch.setattr(
        relay_e2ee.AgentRelayIdentity,
        "load_or_create",
        classmethod(lambda cls, **kw: relay_e2ee.AgentRelayIdentity(agent_priv)),
    )

    client = _RecordingClient()

    class _CM:
        async def __aenter__(self):
            return client

        async def __aexit__(self, *a):
            return False

    monkeypatch.setattr(_burnbar.httpx, "AsyncClient", lambda *a, **k: _CM())

    cfg = PlatformConfig(enabled=True, extra={"access_token": "tok", "home_channel": "burnbar:home"})
    out = await _burnbar._standalone_send(cfg, "burnbar:home", "would-be-plaintext")
    assert "error" in out and "refused" in out["error"].lower()
    assert all(not u.endswith("/messages") for (u, _b) in client.posts)


# --- Key persistence across reloads -----------------------------------------
@requires_relay
def test_relay_identity_persists_and_survives_reload(monkeypatch, tmp_path):
    """A freshly minted agent key is persisted and reloads to the same identity."""
    monkeypatch.setattr(_burnbar, "CURSOR_FILE", tmp_path / "cursor.json")
    monkeypatch.delenv("BURNBAR_RELAY_E2E", raising=False)
    store: dict[str, str] = {}

    import hermes_cli.config as _cfg

    monkeypatch.setattr(_cfg, "save_env_value", lambda k, v: store.__setitem__(k, v), raising=False)
    # Ensure the mint path runs (no key pre-loaded).
    monkeypatch.delenv(_burnbar.RELAY_PRIVATE_KEY_ENV, raising=False)

    cfg = PlatformConfig(enabled=True, extra={"access_token": "tok", "home_channel": "burnbar:home"})
    adapter = BurnBarAdapter(cfg)
    adapter._relay_e2e_enabled = True
    identity = adapter._ensure_relay_identity()
    assert identity is not None
    # The minted private key was persisted under the relay env var.
    assert _burnbar.RELAY_PRIVATE_KEY_ENV in store
    pub_before = adapter._relay_public_key_base64()

    # Reload from the persisted value -> identical key (no rotation across restart).
    reloaded = relay_e2ee.AgentRelayIdentity.load_or_create(
        environ={_burnbar.RELAY_PRIVATE_KEY_ENV: store[_burnbar.RELAY_PRIVATE_KEY_ENV]}
    )
    assert reloaded.public_key_base64 == pub_before


@requires_relay
def test_setup_accepts_nested_phone_relay_key_from_poll_response(monkeypatch):
    """Device-poll may return the phone pubkey inside a client view; setup must still persist E2E."""
    saved: dict[str, str] = {}
    phone_public_key = relay_e2ee.generate_private_key().public_key_base64()
    agent_private_key = relay_e2ee.generate_private_key()
    agent_public_key = agent_private_key.public_key_base64()
    monkeypatch.setattr(_burnbar, "RELAY_CRYPTO_AVAILABLE", True)

    def load_identity(*args, **kwargs):
        environ = kwargs["environ"]
        environ[_burnbar.RELAY_PRIVATE_KEY_ENV] = agent_private_key.raw_base64()
        return type("Identity", (), {"public_key_base64": agent_public_key})()

    monkeypatch.setattr(_burnbar.relay_e2ee.AgentRelayIdentity, "load_or_create", load_identity)
    monkeypatch.setattr("hermes_cli.setup.save_env_value", lambda key, value: saved.__setitem__(key, value))
    monkeypatch.setattr("hermes_cli.setup.get_env_value", lambda key: None)
    monkeypatch.setattr("hermes_cli.setup.prompt", lambda *args, **kwargs: "https://api.example/v1/hermes-gateway")
    prompt_defaults = []

    def confirm_prompt(_question, default=False):
        prompt_defaults.append(default)
        return True

    monkeypatch.setattr("hermes_cli.setup.prompt_yes_no", confirm_prompt)
    monkeypatch.setattr("hermes_cli.setup.print_header", lambda *args, **kwargs: None)
    monkeypatch.setattr("hermes_cli.setup.print_info", lambda *args, **kwargs: None)
    monkeypatch.setattr("hermes_cli.setup.print_success", lambda *args, **kwargs: None)
    monkeypatch.setattr("hermes_cli.setup.print_warning", lambda *args, **kwargs: None)

    class _SyncClient:
        def __init__(self, *args, **kwargs):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

        def post(self, url, json=None):
            if url.endswith("/device/start"):
                assert json["agentRelayPublicKey"] == agent_public_key
                return _FakeResponse({"deviceCode": "dev", "userCode": "AB12-CD34", "interval": 0, "verificationUriComplete": "https://example.test"})
            if url.endswith("/device/poll"):
                return _FakeResponse({
                    "status": "approved",
                    "accessToken": "tok",
                    "homeDestinationId": "burnbar:home",
                    "clientId": "hgw_1",
                    "uid": "uid_1",
                    "client": {"relayCapable": True, "phoneRelayPublicKey": phone_public_key},
                })
            raise AssertionError(url)

    monkeypatch.setattr(_burnbar.httpx, "Client", _SyncClient)

    _burnbar.interactive_setup()

    assert saved[_burnbar.RELAY_E2E_ENV] == "1"
    assert saved["BURNBAR_RELAY_PEER_PUBLIC_KEY"] == phone_public_key
    assert saved["BURNBAR_RELAY_CLIENT_ID"] == "hgw_1"
    assert saved["BURNBAR_RELAY_UID"] == "uid_1"
    assert saved[_burnbar.RELAY_PRIVATE_KEY_ENV] == agent_private_key.raw_base64()
    assert prompt_defaults == [False]


@requires_relay
def test_setup_aborts_e2e_when_grant_missing_routing_ids(monkeypatch):
    """E2E setup requires uid/clientId from the authenticated device grant."""
    saved: dict[str, str] = {}
    warnings = []
    phone_public_key = relay_e2ee.generate_private_key().public_key_base64()
    agent_private_key = relay_e2ee.generate_private_key()
    agent_public_key = agent_private_key.public_key_base64()
    monkeypatch.setattr(_burnbar, "RELAY_CRYPTO_AVAILABLE", True)

    def load_identity(*args, **kwargs):
        environ = kwargs["environ"]
        environ[_burnbar.RELAY_PRIVATE_KEY_ENV] = agent_private_key.raw_base64()
        return type("Identity", (), {"public_key_base64": agent_public_key})()

    monkeypatch.setattr(_burnbar.relay_e2ee.AgentRelayIdentity, "load_or_create", load_identity)
    monkeypatch.setattr("hermes_cli.setup.save_env_value", lambda key, value: saved.__setitem__(key, value))
    monkeypatch.setattr("hermes_cli.setup.get_env_value", lambda key: None)
    monkeypatch.setattr("hermes_cli.setup.prompt", lambda *args, **kwargs: "https://api.example/v1/hermes-gateway")
    monkeypatch.setattr("hermes_cli.setup.prompt_yes_no", lambda *args, **kwargs: True)
    monkeypatch.setattr("hermes_cli.setup.print_header", lambda *args, **kwargs: None)
    monkeypatch.setattr("hermes_cli.setup.print_info", lambda *args, **kwargs: None)
    monkeypatch.setattr("hermes_cli.setup.print_success", lambda *args, **kwargs: None)
    monkeypatch.setattr("hermes_cli.setup.print_warning", lambda message, *args, **kwargs: warnings.append(message))

    class _SyncClient:
        def __init__(self, *args, **kwargs):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

        def post(self, url, json=None):
            if url.endswith("/device/start"):
                return _FakeResponse({
                    "deviceCode": "dev",
                    "userCode": "AB12-CD34",
                    "interval": 0,
                    "verificationUriComplete": "https://example.test",
                })
            if url.endswith("/device/poll"):
                return _FakeResponse({
                    "status": "approved",
                    "accessToken": "tok",
                    "homeDestinationId": "burnbar:home",
                    "client": {"relayCapable": True, "phoneRelayPublicKey": phone_public_key},
                })
            raise AssertionError(url)

    monkeypatch.setattr(_burnbar.httpx, "Client", _SyncClient)

    _burnbar.interactive_setup()

    assert saved == {}
    assert any("without uid/clientId" in warning for warning in warnings)


@requires_relay
def test_setup_legacy_pairing_does_not_persist_new_relay_identity(monkeypatch):
    """A non-E2E grant must not save a freshly minted key that would force must_seal."""
    saved: dict[str, str] = {}
    infos = []
    warnings = []
    agent_private_key = relay_e2ee.generate_private_key()
    agent_public_key = agent_private_key.public_key_base64()
    monkeypatch.delenv(_burnbar.RELAY_PRIVATE_KEY_ENV, raising=False)
    monkeypatch.setattr(_burnbar, "RELAY_CRYPTO_AVAILABLE", True)

    def load_identity(*args, **kwargs):
        environ = kwargs["environ"]
        environ[_burnbar.RELAY_PRIVATE_KEY_ENV] = agent_private_key.raw_base64()
        return type("Identity", (), {"public_key_base64": agent_public_key})()

    monkeypatch.setattr(_burnbar.relay_e2ee.AgentRelayIdentity, "load_or_create", load_identity)
    monkeypatch.setattr("hermes_cli.setup.save_env_value", lambda key, value: saved.__setitem__(key, value))
    monkeypatch.setattr("hermes_cli.setup.get_env_value", lambda key: None)
    monkeypatch.setattr("hermes_cli.setup.prompt", lambda *args, **kwargs: "https://api.example/v1/hermes-gateway")
    monkeypatch.setattr("hermes_cli.setup.prompt_yes_no", lambda *args, **kwargs: True)
    monkeypatch.setattr("hermes_cli.setup.print_header", lambda *args, **kwargs: None)
    monkeypatch.setattr("hermes_cli.setup.print_info", lambda message, *args, **kwargs: infos.append(message))
    monkeypatch.setattr("hermes_cli.setup.print_success", lambda *args, **kwargs: None)
    monkeypatch.setattr("hermes_cli.setup.print_warning", lambda message, *args, **kwargs: warnings.append(message))

    class _SyncClient:
        def __init__(self, *args, **kwargs):
            pass

        def __enter__(self):
            return self

        def __exit__(self, *args):
            return False

        def post(self, url, json=None):
            if url.endswith("/device/start"):
                assert json["agentRelayPublicKey"] == agent_public_key
                return _FakeResponse({"deviceCode": "dev", "userCode": "AB12-CD34", "interval": 0, "verificationUriComplete": "https://example.test"})
            if url.endswith("/device/poll"):
                return _FakeResponse({
                    "status": "approved",
                    "accessToken": "tok",
                    "homeDestinationId": "burnbar:home",
                    "relayCapable": False,
                })
            raise AssertionError(url)

    monkeypatch.setattr(_burnbar.httpx, "Client", _SyncClient)

    _burnbar.interactive_setup()

    assert saved["BURNBAR_ACCESS_TOKEN"] == "tok"
    assert _burnbar.RELAY_PRIVATE_KEY_ENV not in saved
    assert _burnbar.RELAY_E2E_ENV not in saved
    assert any("No relay private key was saved" in info for info in infos)
    assert warnings == []


# --- Replay rejection before message dispatch -------------------------------
@requires_relay
@pytest.mark.asyncio
async def test_duplicate_event_id_is_dropped(monkeypatch, tmp_path):
    """A redelivered (duplicate id) event is dropped before reaching Hermes."""
    adapter = _legacy_adapter(monkeypatch, tmp_path)
    received = []

    async def capture(event):
        received.append(event)

    adapter.handle_message = capture
    payload = {
        "id": "evt_dup",
        "destinationId": "burnbar:home",
        "senderId": "s",
        "text": "deliver once",
    }
    await adapter._handle_burnbar_event(dict(payload))
    await adapter._handle_burnbar_event(dict(payload))  # relay redelivery
    await adapter._handle_burnbar_event(dict(payload))  # again
    assert len(received) == 1  # only the first delivery is handled


@requires_relay
@pytest.mark.asyncio
async def test_duplicate_sealed_event_id_uses_envelope_id_when_top_level_id_missing(monkeypatch, tmp_path):
    """A relay cannot bypass dedup by stripping top-level id from a sealed event."""
    _no_persist(monkeypatch)
    phone_priv = relay_e2ee.generate_private_key()
    phone_pub = phone_priv.public_key_base64()
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=phone_pub)
    agent_pub = adapter._relay_public_key_base64()

    event_id = "evt_dup_envelope_only"
    payload_aad = _burnbar._gateway_event_aad("uid-1", "client-1", event_id)
    key_aad = _burnbar._gateway_event_key_aad("uid-1", "client-1", event_id)
    sym = relay_e2ee.generate_symmetric_key()
    payload_ct = relay_e2ee.seal_to_base64(
        json.dumps({"text": "deliver once", "destinationId": "burnbar:home", "replayCounter": 1}).encode(),
        sym,
        payload_aad,
    )
    wrapped = relay_e2ee.wrap_symmetric_key(sym, agent_pub, key_aad, sender_private=phone_priv)

    received = []
    adapter.handle_message = lambda e: received.append(e) or _noop()
    payload = {
        "destinationId": "burnbar:home",
        "senderId": "s",
        "senderPublicKey": phone_pub,
        "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
        "relayEnvelope": {
            "eventId": event_id,
            "payloadCiphertext": payload_ct,
            "wrappedKey": wrapped,
            "senderPublicKey": phone_pub,
            "relayEncryption": _burnbar.RELAY_ENCRYPTION,
            "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
        },
    }

    await adapter._handle_burnbar_event(dict(payload))
    await adapter._handle_burnbar_event(dict(payload))
    assert len(received) == 1


def test_seen_event_id_cache_is_bounded(monkeypatch, tmp_path):
    """The replay cache never grows past MAX_SEEN_EVENT_IDS."""
    adapter = _legacy_adapter(monkeypatch, tmp_path)
    monkeypatch.setattr(_burnbar, "MAX_SEEN_EVENT_IDS", 8)
    # _is_event_seen is read-only; recording happens in _record_event AFTER a
    # successful authenticated open, so only authenticated ids consume a slot.
    for i in range(50):
        assert adapter._is_event_seen(f"id-{i}") is False
        adapter._record_event(f"id-{i}")
    assert len(adapter._seen_event_ids) <= 8
    # The most recently recorded id is still considered a duplicate.
    assert adapter._is_event_seen("id-49") is True


@requires_relay
@pytest.mark.asyncio
async def test_sealed_replay_counter_blocks_evicted_old_event(monkeypatch, tmp_path):
    """High-water replayCounter closes the bounded-cache saturation replay window."""
    _no_persist(monkeypatch)
    monkeypatch.setattr(_burnbar, "MAX_SEEN_EVENT_IDS", 3)
    phone_priv = relay_e2ee.generate_private_key()
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=phone_priv.public_key_base64())

    received = []
    adapter.handle_message = lambda e: received.append(e) or _noop()

    first = _phone_sealed_event(
        adapter,
        phone_priv,
        "evt-counter-1",
        {"text": "run once", "replayCounter": 1},
    )
    await adapter._handle_burnbar_event(first)
    assert [event.text for event in received] == ["run once"]

    # Saturate the bounded id cache with newer authenticated events. The first id
    # is no longer in the cache, so a pure id-cache defense would accept it once.
    for counter in range(2, 7):
        await adapter._handle_burnbar_event(
            _phone_sealed_event(
                adapter,
                phone_priv,
                f"evt-counter-{counter}",
                {"text": f"new {counter}", "replayCounter": counter},
            )
        )
    assert adapter._event_replay_key("evt-counter-1") not in adapter._seen_event_ids
    assert adapter._event_replay_high_water == 6

    before = len(received)
    await adapter._handle_burnbar_event(first)
    assert len(received) == before
    assert [event.text for event in received].count("run once") == 1


@requires_relay
@pytest.mark.asyncio
async def test_e2e_sealed_event_requires_authenticated_replay_counter(monkeypatch, tmp_path):
    """Counterless sealed events are fail-closed; bounded id caches are not enough."""
    _no_persist(monkeypatch)
    phone_priv = relay_e2ee.generate_private_key()
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=phone_priv.public_key_base64())

    received = []
    adapter.handle_message = lambda e: received.append(e) or _noop()
    raw = _phone_sealed_event(adapter, phone_priv, "evt_missing_counter", {"text": "must drop"})

    await adapter._handle_burnbar_event(raw)

    assert received == []
    assert adapter._event_replay_key("evt_missing_counter") not in adapter._seen_event_ids


@requires_relay
def test_replay_ledger_persists_authenticated_high_water(monkeypatch, tmp_path):
    """Restarted adapters load the sender-counter high-water mark, not just ids."""
    replay_file = tmp_path / "replay.json"
    monkeypatch.setattr(_burnbar, "REPLAY_LEDGER_FILE", replay_file)
    phone_priv = relay_e2ee.generate_private_key()
    phone_pub = phone_priv.public_key_base64()

    adapter1, _ = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=phone_pub)
    assert adapter1._record_event("evt-high-water", replay_counter=9) is True

    adapter2, _ = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=phone_pub)
    assert adapter2._event_replay_high_water == 9
    assert adapter2._is_replay_counter_seen(8) is True
    assert adapter2._is_replay_counter_seen(9) is True
    assert adapter2._is_replay_counter_seen(10) is False


@requires_relay
def test_replay_ledger_persist_handles_short_os_write(monkeypatch, tmp_path):
    """A short os.write cannot silently install a truncated replay ledger."""
    replay_file = tmp_path / "replay.json"
    monkeypatch.setattr(_burnbar, "REPLAY_LEDGER_FILE", replay_file)
    phone_priv = relay_e2ee.generate_private_key()
    adapter, _ = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=phone_priv.public_key_base64())

    original_write = os.write
    calls = 0

    def one_byte_write(fd, data):
        nonlocal calls
        calls += 1
        return original_write(fd, data[:1])

    monkeypatch.setattr(_burnbar.os, "write", one_byte_write)

    assert adapter._record_event("evt-short-write", replay_counter=9) is True
    assert calls > 1

    ledger = json.loads(replay_file.read_text())
    entry = ledger[adapter._replay_ledger_bucket()]
    assert entry["highWater"] == 9
    assert adapter._event_replay_key("evt-short-write") in entry["ids"]


@requires_relay
@pytest.mark.asyncio
async def test_corrupt_replay_ledger_fails_closed_on_e2e_event(monkeypatch, tmp_path, caplog):
    """A malformed replay ledger is loud and blocks E2E side effects."""
    replay_file = tmp_path / "replay.json"
    replay_file.write_text("{")
    monkeypatch.setattr(_burnbar, "REPLAY_LEDGER_FILE", replay_file)
    caplog.set_level(logging.WARNING)

    phone_priv = relay_e2ee.generate_private_key()
    adapter, _ = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=phone_priv.public_key_base64())
    received = []
    adapter.handle_message = lambda e: received.append(e) or _noop()

    event_id = "evt_corrupt_replay_ledger"
    await adapter._handle_burnbar_event(
        _phone_sealed_event(
            adapter,
            phone_priv,
            event_id,
            {"text": "must not dispatch", "replayCounter": 1},
        )
    )

    assert received == []
    assert adapter._event_replay_key(event_id) not in adapter._seen_event_ids
    assert "is not valid JSON" in caplog.text
    assert "cannot be trusted" in caplog.text


# --- Model switches must be sealed on E2E links -----------------------------
@requires_relay
@pytest.mark.asyncio
async def test_unsealed_model_switch_rejected_on_e2e_link(monkeypatch, tmp_path):
    """A cleartext model_switch on an E2E-paired link is dropped (injectable control)."""
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path)
    received = []

    async def capture(event):
        received.append(event)

    adapter.handle_message = capture
    await adapter._handle_burnbar_event(
        {"id": "evt_ms_plain", "kind": "model_switch", "modelId": "evil/model", "destinationId": "burnbar:home"}
    )
    assert received == []  # refused: no cleartext control event on a paired link


@requires_relay
@pytest.mark.asyncio
async def test_sealed_model_switch_opens_on_e2e_link(monkeypatch, tmp_path):
    """A model_switch sealed to the agent pubkey opens and applies on an E2E link."""
    _no_persist(monkeypatch)
    phone_priv = relay_e2ee.generate_private_key()
    phone_pub = phone_priv.public_key_base64()
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=phone_pub)
    agent_pub = adapter._relay_public_key_base64()
    received = []

    async def capture(event):
        received.append(event)

    adapter.handle_message = capture
    adapter._publish_runtime_status = lambda *a, **k: _noop()

    event_id = "evt_ms_sealed"
    payload_aad = _burnbar._gateway_event_aad("uid-1", "client-1", event_id)
    key_aad = _burnbar._gateway_event_key_aad("uid-1", "client-1", event_id)
    sym = relay_e2ee.generate_symmetric_key()
    payload_ct = relay_e2ee.seal_to_base64(
        json.dumps(
            {
                "kind": "model_switch",
                "modelId": "anthropic/claude",
                "destinationId": "burnbar:home",
                "replayCounter": 1,
            }
        ).encode(),
        sym,
        payload_aad,
    )
    wrapped = relay_e2ee.wrap_symmetric_key(sym, agent_pub, key_aad, sender_private=phone_priv)
    await adapter._handle_burnbar_event(
        {
            "id": event_id,
            "kind": "model_switch",
            "destinationId": "burnbar:home",
            "senderPublicKey": phone_pub,
            "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
            "relayEnvelope": {
                "payloadCiphertext": payload_ct,
                "wrappedKey": wrapped,
                "senderPublicKey": phone_pub,
                "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
            },
        }
    )
    assert received and received[0].text == "/model anthropic/claude"


@requires_relay
def test_seal_model_switch_round_trip(monkeypatch, tmp_path):
    """seal_model_switch produces an envelope the peer opens under gateway event AAD."""
    phone_priv = relay_e2ee.generate_private_key()
    adapter, _agent = _e2e_adapter(
        monkeypatch, tmp_path, peer_public_key=phone_priv.public_key_base64()
    )
    env = adapter._sealer.seal_model_switch(destination_id="burnbar:home", model_id="openai/gpt")
    # v2 authenticated wrap: stamped gateway version + the agent's own pub as sender.
    assert env["relayKeyVersion"] == _burnbar.GATEWAY_RELAY_KEY_VERSION
    assert env["senderPublicKey"] == _agent.public_key_base64()
    payload_aad = _burnbar._gateway_event_aad("uid-1", "client-1", env["eventId"])
    key_aad = _burnbar._gateway_event_key_aad("uid-1", "client-1", env["eventId"])
    sym = relay_e2ee.unwrap_symmetric_key(
        env["wrappedKey"], phone_priv, key_aad, sender_public_base64=env["senderPublicKey"]
    )
    opened = json.loads(relay_e2ee.open_base64(env["payloadCiphertext"], sym, payload_aad).decode())
    assert opened == {"kind": "model_switch", "modelId": "openai/gpt", "destinationId": "burnbar:home"}


# --- Replay dedup uses the same stable id that AAD binds ---------------------
@requires_relay
@pytest.mark.asyncio
async def test_sealed_redelivery_dropped_by_envelope_event_id(monkeypatch, tmp_path):
    """A sealed event whose top-level `id` is stripped is still deduped.

    The malicious relay can blank `raw["id"]` while the envelope still carries
    the `eventId` the AAD binds. Dedup must key on the same stable id the AAD
    resolves from (`raw["id"] or envelope.eventId`), so the captured sealed
    command runs exactly once and a redelivery is dropped — not re-triggered on
    every poll. The first delivery opens (proving the id is the AAD-bound one).
    """
    _no_persist(monkeypatch)
    phone_priv = relay_e2ee.generate_private_key()
    phone_pub = phone_priv.public_key_base64()
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=phone_pub)
    agent_pub = adapter._relay_public_key_base64()

    # The AAD-bound id lives in the envelope (top-level id is stripped by the relay).
    event_id = "evt_sealed_stripped"
    payload_aad = _burnbar._gateway_event_aad("uid-1", "client-1", event_id)
    key_aad = _burnbar._gateway_event_key_aad("uid-1", "client-1", event_id)
    sym = relay_e2ee.generate_symmetric_key()
    payload = json.dumps(
        {"text": "run once", "destinationId": "burnbar:home", "replayCounter": 1}
    ).encode()
    payload_ct = relay_e2ee.seal_to_base64(payload, sym, payload_aad)
    wrapped = relay_e2ee.wrap_symmetric_key(sym, agent_pub, key_aad, sender_private=phone_priv)

    received = []

    async def capture(event):
        received.append(event)

    adapter.handle_message = capture
    raw = {
        # No top-level "id" — the relay stripped it; the id lives in the envelope.
        "destinationId": "burnbar:home",
        "senderId": "burnbar-user",
        "senderPublicKey": phone_pub,
        "relayEnvelope": {
            "payloadCiphertext": payload_ct,
            "wrappedKey": wrapped,
            "senderPublicKey": phone_pub,
            "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
            "eventId": event_id,
        },
    }
    await adapter._handle_burnbar_event(dict(raw))
    # The dedup key recorded the AAD-bound id even though raw["id"] was absent.
    assert adapter._event_replay_key(event_id) in adapter._seen_event_ids
    await adapter._handle_burnbar_event(dict(raw))  # relay redelivery
    await adapter._handle_burnbar_event(dict(raw))  # again
    # Opened + handled exactly once; every redelivery is dropped.
    assert len(received) == 1
    assert received[0].text == "run once"


# --- TOFU pin-jacking: never seed a new pin from an untrusted relay response --
@requires_relay
def test_pin_peer_key_refuses_new_pin_from_untrusted_source(monkeypatch, tmp_path):
    """With no pin present, an untrusted source (allow_new_pin=False) must not pin."""
    _no_persist(monkeypatch)
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path)  # E2E on, no pin
    assert adapter._peer_public_key is None

    attacker = relay_e2ee.generate_private_key().public_key_base64()
    # Untrusted runtime source: refuse to establish the first pin.
    assert (
        adapter._pin_peer_public_key("burnbar:home", attacker, source="state", allow_new_pin=False)
        is False
    )
    assert adapter._peer_public_key is None  # not pin-jacked

    # The authenticated pairing path may still seed it, but only by explicit opt-in.
    real = relay_e2ee.generate_private_key().public_key_base64()
    assert (
        adapter._pin_peer_public_key(
            "burnbar:home", real, source="pairing", allow_new_pin=True
        )
        is True
    )
    assert adapter._peer_public_key == real


@requires_relay
def test_pin_peer_key_default_refuses_new_pin(monkeypatch, tmp_path):
    """Default call posture is fail-closed; authenticated pairing must opt in."""
    _no_persist(monkeypatch)
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path)
    attacker = relay_e2ee.generate_private_key().public_key_base64()

    assert adapter._pin_peer_public_key("burnbar:home", attacker, source="state") is False
    assert adapter._peer_public_key is None


@requires_relay
def test_absorb_relay_state_does_not_seed_pin_from_untrusted_destinations(monkeypatch, tmp_path):
    """E2E on + no persisted pin: a /destinations|/state response cannot TOFU-seed a key."""
    _no_persist(monkeypatch)
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path)  # E2E on, no pin
    assert adapter._peer_public_key is None

    attacker = relay_e2ee.generate_private_key().public_key_base64()
    # This is exactly the untrusted live path (connect()/_poll_once feed it).
    adapter._absorb_relay_state({"relayPublicKey": attacker, "destinationId": "burnbar:home"})
    # No pin is adopted from the relay; the adapter refuses rather than pinning from relay state.
    assert adapter._peer_public_key is None


@requires_relay
@pytest.mark.asyncio
async def test_pin_jacking_refused_then_send_fails_closed(monkeypatch, tmp_path):
    """Full pin-jacking scenario: E2E on, pin lost, untrusted /destinations -> refuse, then send refuses."""
    _no_persist(monkeypatch)
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path)  # E2E on, no pin
    adapter._client = _RecordingClient(
        get_responses={"/destinations": _FakeResponse({"relayPublicKey": "ATTACKER"})}
    )

    # Absorbing the untrusted /destinations response must not seed the attacker key.
    adapter._absorb_relay_state({"relayPublicKey": "ATTACKER", "destinationId": "burnbar:home"})
    assert adapter._peer_public_key is None

    # With no pin and E2E required, the send path fails closed (never plaintext,
    # never sealed-to-attacker).
    result = await adapter.send("burnbar:home", "must-not-seal-to-attacker")
    assert result.success is False
    assert all(not u.endswith("/messages") for (u, _b) in adapter._client.posts)


@requires_relay
def test_untrusted_runtime_does_not_flip_unpaired_agent_into_e2e(monkeypatch, tmp_path):
    """relayCapable/e2eEnabled from an untrusted response must not promote a never-paired agent."""
    adapter = _legacy_adapter(monkeypatch, tmp_path)  # E2E not negotiated
    assert adapter._relay_e2e_enabled is False

    adapter._absorb_relay_state(
        {"relayCapable": True, "e2eEnabled": True, "relayPublicKey": "ATTACKER", "destinationId": "burnbar:home"}
    )
    # The untrusted relay cannot fabricate an "encrypted" state or pin a key.
    assert adapter._relay_e2e_enabled is False
    assert adapter._peer_public_key is None


@requires_relay
def test_absorb_relay_state_confirms_existing_pin_from_runtime(monkeypatch, tmp_path):
    """A runtime response RE-advertising the already-pinned key is accepted (idempotent)."""
    _no_persist(monkeypatch)
    pinned = relay_e2ee.generate_private_key().public_key_base64()
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=pinned)

    # Same key re-advertised by the relay: harmless confirm, pin unchanged.
    adapter._absorb_relay_state({"relayPublicKey": pinned, "destinationId": "burnbar:home"})
    assert adapter._peer_public_key == pinned


# ---------------------------------------------------------------------------
# Relay E2E regression tests: each covers a protocol boundary that previously
# failed under adversarial review.
# ---------------------------------------------------------------------------
@requires_relay
@pytest.mark.asyncio
async def test_forged_id_flood_does_not_evict_a_genuine_pending_id(monkeypatch, tmp_path):
    """A relay flooding forged-id events (every one fails AEAD) cannot evict a
    genuine authenticated id from the bounded replay cache. The id is recorded only
    AFTER a successful authenticated open, so forged frames never consume a slot."""
    _no_persist(monkeypatch)
    monkeypatch.setattr(_burnbar, "MAX_SEEN_EVENT_IDS", 4)
    phone_priv = relay_e2ee.generate_private_key()
    phone_pub = phone_priv.public_key_base64()
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=phone_pub)
    agent_pub = adapter._relay_public_key_base64()

    received = []
    adapter.handle_message = lambda e: received.append(e) or _noop()

    def _sealed_event(event_id, text, *, sender_private):
        payload_aad = _burnbar._gateway_event_aad("uid-1", "client-1", event_id)
        key_aad = _burnbar._gateway_event_key_aad("uid-1", "client-1", event_id)
        sym = relay_e2ee.generate_symmetric_key()
        ct = relay_e2ee.seal_to_base64(
            json.dumps({"text": text, "destinationId": "burnbar:home", "replayCounter": 1}).encode(),
            sym,
            payload_aad,
        )
        wrapped = relay_e2ee.wrap_symmetric_key(sym, agent_pub, key_aad, sender_private=sender_private)
        return {
            "id": event_id,
            "destinationId": "burnbar:home",
            "senderPublicKey": phone_pub,
            "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
            "relayEnvelope": {
                "payloadCiphertext": ct,
                "wrappedKey": wrapped,
                "senderPublicKey": phone_pub,
                "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
            },
        }

    # A genuine event from the pinned phone authenticates and is recorded.
    await adapter._handle_burnbar_event(_sealed_event("genuine-1", "real", sender_private=phone_priv))
    genuine_key = adapter._event_replay_key("genuine-1")
    assert genuine_key in adapter._seen_event_ids

    # Flood with forged events: well-formed v2 envelopes sealed by a different sender
    # key, so the pinned-sender unwrap fails the AEAD tag. None may be recorded.
    for i in range(50):
        attacker = relay_e2ee.generate_private_key()
        await adapter._handle_burnbar_event(_sealed_event(f"forged-{i}", "x", sender_private=attacker))

    # The genuine id survived the flood (forged frames never consumed a cache slot)...
    assert genuine_key in adapter._seen_event_ids
    assert len(adapter._seen_event_ids) == 1
    # ...and a redelivery of the genuine event is still dropped as a replay.
    before = len(received)
    await adapter._handle_burnbar_event(_sealed_event("genuine-1", "real", sender_private=phone_priv))
    assert len(received) == before


@requires_relay
@pytest.mark.asyncio
async def test_sealed_reply_is_undecryptable_if_messageId_not_echoed(monkeypatch, tmp_path):
    """The message AAD binds the echoed messageId. If the server assigned a
    different id (i.e. the agent had not echoed it), the phone rebuilds the AAD from
    that id and AEAD fails, which is why ``body['messageId']`` must round-trip."""
    from cryptography.exceptions import InvalidTag

    phone_priv = relay_e2ee.generate_private_key()
    adapter, _agent = _e2e_adapter(
        monkeypatch, tmp_path, peer_public_key=phone_priv.public_key_base64()
    )
    client = _RecordingClient(post_responses={"/messages": _FakeResponse({"message": {"id": "m1"}})})
    adapter._client = client
    assert (await adapter.send("burnbar:home", "secret reply")).success is True

    _, body = client.posts[-1]
    env = body["relayEnvelope"]
    assert body["messageId"] == env["messageId"]  # the id echoed back to the phone

    # With the echoed id the phone opens it.
    sym = relay_e2ee.unwrap_symmetric_key(
        env["wrappedKey"], phone_priv,
        _burnbar._gateway_message_key_aad("uid-1", "client-1", body["messageId"]),
        sender_public_base64=env["senderPublicKey"],
    )
    opened = relay_e2ee.open_base64(
        env["payloadCiphertext"], sym,
        _burnbar._gateway_message_aad("uid-1", "client-1", body["messageId"]),
    )
    assert json.loads(opened.decode()) == {"text": "secret reply", "destinationId": "burnbar:home"}

    # Had the server minted a different id (no echo), the key-wrap AAD no longer matches.
    with pytest.raises(InvalidTag):
        relay_e2ee.unwrap_symmetric_key(
            env["wrappedKey"], phone_priv,
            _burnbar._gateway_message_key_aad("uid-1", "client-1", "server_minted_other_id"),
            sender_public_base64=env["senderPublicKey"],
        )


@requires_relay
@pytest.mark.asyncio
async def test_arm_approval_carries_no_free_text(monkeypatch, tmp_path):
    """The /approvals control-plane body carries only opaque ids, never the
    slash-confirm summary / command text / file paths the untrusted relay would see."""
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path)
    client = _RecordingClient(post_responses={"/approvals": _FakeResponse({})})
    adapter._client = client

    await adapter._arm_approval(action_id="act-1", tool_name="Bash", destination_id="burnbar:home")

    url, body = next((u, b) for (u, b) in client.posts if u.endswith("/approvals"))
    assert body.get("actionId") == "act-1"
    assert "summary" not in body
    # Only opaque/coarse control fields are allowed on the relay-visible channel.
    assert set(body).issubset({"actionId", "toolName", "destinationId"})

# --- Additional relay E2E regressions ---------------------------------------


@requires_relay
@pytest.mark.asyncio
async def test_post_message_echoes_aad_bound_message_id(monkeypatch, tmp_path):
    """The agent lifts the AAD-bound messageId to the top-level body so the
    server adopts it; a server-minted different id would fail the phone's AEAD."""
    from cryptography.exceptions import InvalidTag

    phone_priv = relay_e2ee.generate_private_key()
    adapter, _agent = _e2e_adapter(
        monkeypatch, tmp_path, peer_public_key=phone_priv.public_key_base64()
    )
    adapter._client = _RecordingClient(
        post_responses={"/messages": _FakeResponse({"message": {"id": "m1"}})}
    )

    assert (await adapter.send("burnbar:home", "secret reply")).success is True
    _, body = adapter._client.posts[-1]
    env = body["relayEnvelope"]
    assert body["messageId"] == env["messageId"]

    # Rebuilding the AAD from a different (server-minted) id fails AEAD; echoing
    # the agent-generated id is what keeps the phone's AAD in sync.
    with pytest.raises(InvalidTag):
        relay_e2ee.unwrap_symmetric_key(
            env["wrappedKey"],
            phone_priv,
            _burnbar._gateway_message_key_aad("uid-1", "client-1", "msg_server_minted_different"),
            sender_public_base64=env["senderPublicKey"],
        )


@requires_relay
@pytest.mark.asyncio
async def test_init_attachment_echoes_attachment_id_and_omits_contenttype(monkeypatch, tmp_path):
    """The agent echoes the AAD-bound attachmentId so the server adopts it;
    the real contentType is never sent plaintext on the sealed path."""
    phone_priv = relay_e2ee.generate_private_key()
    adapter, _agent = _e2e_adapter(
        monkeypatch, tmp_path, peer_public_key=phone_priv.public_key_base64()
    )
    f = tmp_path / "report.pdf"
    f.write_bytes(b"%PDF-1.4 secret contents")
    adapter._client = _RecordingClient(post_responses={
        # Faithful server: adopt the client-supplied attachmentId (adoptedGatewayDocId).
        "/attachments/init": lambda b: _FakeResponse(
            {"attachment": {"id": b["attachmentId"]}, "uploadURL": "https://up/x"}
        ),
        "/attachments/finalize": _FakeResponse({}),
        "/messages": _FakeResponse({"message": {"id": "m1"}}),
    })

    assert (await adapter.send_document("burnbar:home", str(f), caption="here")).success is True
    init_body = next(b for (u, b) in adapter._client.posts if u.endswith("/attachments/init"))
    assert init_body["attachmentId"] == init_body["relayEnvelope"]["attachmentId"]
    assert "contentType" not in init_body  # real media type stays sealed


@requires_relay
@pytest.mark.asyncio
async def test_arm_approval_body_has_no_free_text_on_relay(monkeypatch, tmp_path):
    """The /approvals control-plane body carries only the opaque actionId +
    coarse toolName + destination, never free text the untrusted relay could read."""
    adapter, _agent = _e2e_adapter(
        monkeypatch, tmp_path, peer_public_key=relay_e2ee.generate_private_key().public_key_base64()
    )
    adapter._client = _RecordingClient(post_responses={"/approvals": _FakeResponse({})})
    assert await adapter._arm_approval(action_id="act_1", tool_name="Bash", destination_id="burnbar:home")
    _, body = adapter._client.posts[-1]
    assert body == {"actionId": "act_1", "toolName": "Bash", "destinationId": "burnbar:home"}
    assert "summary" not in body


@requires_relay
@pytest.mark.asyncio
async def test_sealed_followup_carries_actionid(monkeypatch, tmp_path):
    """The human-readable approval detail rides ENCRYPTED with the
    actionId (so the phone binds detail->gate); /approvals stays free-text-free."""
    phone_priv = relay_e2ee.generate_private_key()
    adapter, _agent = _e2e_adapter(
        monkeypatch, tmp_path, peer_public_key=phone_priv.public_key_base64()
    )
    adapter._oversight_mode = "supervised"
    adapter._client = _RecordingClient(post_responses={
        "/approvals": _FakeResponse({}),
        "/messages": _FakeResponse({"message": {"id": "m1"}}),
    })
    res = await adapter.send_slash_confirm(
        "burnbar:home", "Run command", "rm -rf /tmp/x", "sess", "act_42", None
    )
    assert res.success is True
    approvals_body = next(b for (u, b) in adapter._client.posts if u.endswith("/approvals"))
    assert "summary" not in approvals_body
    assert "rm -rf" not in json.dumps(approvals_body)

    msg_body = next(b for (u, b) in adapter._client.posts if u.endswith("/messages"))
    env = msg_body["relayEnvelope"]
    mid = env["messageId"]
    sym = relay_e2ee.unwrap_symmetric_key(
        env["wrappedKey"], phone_priv,
        _burnbar._gateway_message_key_aad("uid-1", "client-1", mid),
        sender_public_base64=env["senderPublicKey"],
    )
    opened = json.loads(relay_e2ee.open_base64(
        env["payloadCiphertext"], sym, _burnbar._gateway_message_aad("uid-1", "client-1", mid)
    ).decode())
    assert opened["actionId"] == "act_42"
    assert opened["kind"] == "approval"
    assert "rm -rf" in opened["text"]  # detail is end-to-end encrypted, not plaintext


@requires_relay
@pytest.mark.asyncio
async def test_failed_open_does_not_record_event_id(monkeypatch, tmp_path):
    """An event that fails to authenticate must not record its id, so a forged-
    id flood (all failing AEAD) cannot evict a genuine pending id from the cache."""
    phone_priv = relay_e2ee.generate_private_key()
    adapter, _agent = _e2e_adapter(
        monkeypatch, tmp_path, peer_public_key=phone_priv.public_key_base64()
    )
    received = []

    async def capture(event):
        received.append(event)

    adapter.handle_message = capture

    # A v2 frame sealed to the WRONG recipient: the agent's unwrap fails AEAD.
    wrong_recipient = relay_e2ee.generate_private_key()
    eid = "evt_forged"
    sym = relay_e2ee.generate_symmetric_key()
    payload_ct = relay_e2ee.seal_to_base64(
        json.dumps({"text": "x"}).encode(), sym,
        _burnbar._gateway_event_aad("uid-1", "client-1", eid),
    )
    wrapped = relay_e2ee.wrap_symmetric_key(
        sym, wrong_recipient.public_key_base64(),
        _burnbar._gateway_event_key_aad("uid-1", "client-1", eid),
        sender_private=phone_priv,
    )
    await adapter._handle_burnbar_event({
        "id": eid, "destinationId": "burnbar:home",
        "relayEnvelope": {
            "payloadCiphertext": payload_ct, "wrappedKey": wrapped,
            "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
            "senderPublicKey": phone_priv.public_key_base64(),
        },
    })
    assert received == []  # failed to authenticate
    key = adapter._event_replay_key(eid)
    assert key not in adapter._seen_event_ids  # id recorded only AFTER auth


@requires_relay
@pytest.mark.asyncio
async def test_sender_identity_from_sealed_payload(monkeypatch, tmp_path):
    """On an authenticated sealed event, sender identity is taken from the
    sealed payload, never from relay-controlled top-level metadata."""
    phone_priv = relay_e2ee.generate_private_key()
    phone_pub = phone_priv.public_key_base64()
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=phone_pub)
    agent_pub = adapter._relay_public_key_base64()
    eid = "evt_sender_identity"
    sym = relay_e2ee.generate_symmetric_key()
    payload_ct = relay_e2ee.seal_to_base64(
        json.dumps(
            {
                "text": "hi",
                "destinationId": "burnbar:home",
                "senderId": "real-user",
                "senderDisplayName": "Real",
                "replayCounter": 1,
            }
        ).encode(),
        sym, _burnbar._gateway_event_aad("uid-1", "client-1", eid),
    )
    wrapped = relay_e2ee.wrap_symmetric_key(
        sym, agent_pub, _burnbar._gateway_event_key_aad("uid-1", "client-1", eid),
        sender_private=phone_priv,
    )
    received = []

    async def capture(event):
        received.append(event)

    adapter.handle_message = capture
    await adapter._handle_burnbar_event({
        "id": eid, "destinationId": "burnbar:home",
        "senderId": "spoofed-by-relay", "senderDisplayName": "Spoofed",
        "relayEnvelope": {
            "payloadCiphertext": payload_ct, "wrappedKey": wrapped,
            "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
            "senderPublicKey": phone_pub,
        },
    })
    assert len(received) == 1
    assert received[0].source.user_id == "real-user"
    assert received[0].source.user_name == "Real"


def test_relay_cannot_rotate_pinned_routing_ids(monkeypatch, tmp_path):
    """Once uid/clientId are pinned, an untrusted runtime response cannot
    rotate them (they bind every gateway AAD)."""
    monkeypatch.setenv("BURNBAR_RELAY_UID", "uid-pinned")
    monkeypatch.setenv("BURNBAR_RELAY_CLIENT_ID", "client-pinned")
    adapter = _legacy_adapter(monkeypatch, tmp_path)
    assert adapter._relay_uid == "uid-pinned"
    adapter._absorb_relay_state({"uid": "uid-attacker", "clientId": "client-attacker"})
    assert adapter._relay_uid == "uid-pinned"
    assert adapter._relay_client_id == "client-pinned"


@requires_relay
@pytest.mark.asyncio
async def test_e2e_missing_routing_ids_fails_closed_for_send_and_receive(monkeypatch, tmp_path):
    """E2E cannot learn uid/clientId from the first untrusted relay poll."""
    _no_persist(monkeypatch)
    monkeypatch.setattr(_burnbar, "CURSOR_FILE", tmp_path / "cursor.json")
    monkeypatch.setattr(_burnbar, "REPLAY_LEDGER_FILE", tmp_path / "replay.json")
    monkeypatch.setenv(_burnbar.RELAY_E2E_ENV, "1")
    monkeypatch.setenv(_burnbar.RELAY_PRIVATE_KEY_ENV, relay_e2ee.generate_private_key().raw_base64())
    phone_priv = relay_e2ee.generate_private_key()
    monkeypatch.setenv("BURNBAR_RELAY_PEER_PUBLIC_KEY", phone_priv.public_key_base64())
    monkeypatch.delenv("BURNBAR_RELAY_UID", raising=False)
    monkeypatch.delenv("BURNBAR_RELAY_CLIENT_ID", raising=False)
    cfg = PlatformConfig(enabled=True, extra={"access_token": "tok", "home_channel": "burnbar:home"})
    adapter = BurnBarAdapter(cfg)

    assert adapter._relay_e2e_config_error
    adapter._absorb_relay_state({"uid": "uid-from-relay", "clientId": "client-from-relay"})
    assert adapter._relay_uid == ""
    assert adapter._relay_client_id == ""
    assert adapter._relay_uid_pinned is False
    assert adapter._relay_client_id_pinned is False

    adapter._client = _RecordingClient(post_responses={"/messages": _FakeResponse({"message": {"id": "m1"}})})
    send_result = await adapter.send("burnbar:home", "must not send")
    assert send_result.success is False
    assert "BURNBAR_RELAY_UID" in (send_result.error or "")
    assert adapter._client.posts == []

    received = []
    adapter.handle_message = lambda e: received.append(e) or _noop()
    raw = _phone_sealed_event(
        adapter,
        phone_priv,
        "evt_missing_routing_ids",
        {"text": "must not receive", "replayCounter": 1},
    )
    await adapter._handle_burnbar_event(raw)
    assert received == []
    assert adapter._event_replay_key("evt_missing_routing_ids") not in adapter._seen_event_ids


@pytest.mark.asyncio
async def test_unsafe_model_id_is_rejected(monkeypatch, tmp_path):
    """A model_switch whose modelId could inject slash flags / control chars
    is dropped; a clean catalog id is accepted."""
    adapter = _legacy_adapter(monkeypatch, tmp_path)
    received = []

    async def capture(event):
        received.append(event)

    adapter.handle_message = capture
    for i, bad in enumerate(["model --global", "-rf", "evil id", "x;y", "a" * 200]):
        await adapter._handle_burnbar_event(
            {"id": f"evt_bad_{i}", "kind": "model_switch", "modelId": bad, "destinationId": "burnbar:home"}
        )
    assert received == []
    await adapter._handle_burnbar_event(
        {"id": "evt_ok", "kind": "model_switch", "modelId": "anthropic/claude-opus-4", "destinationId": "burnbar:home"}
    )
    assert len(received) == 1
    assert received[0].text == "/model anthropic/claude-opus-4"


@requires_relay
@pytest.mark.asyncio
async def test_e2e_capable_agent_refuses_plaintext_without_optin(monkeypatch, tmp_path):
    """An agent holding a relay identity but not E2E-paired refuses plaintext
    unless BURNBAR_ALLOW_PLAINTEXT=1; the relay cannot elect plaintext."""
    monkeypatch.setattr(_burnbar, "CURSOR_FILE", tmp_path / "cursor.json")
    monkeypatch.setenv("BURNBAR_RELAY_PRIVATE_KEY", relay_e2ee.generate_private_key().raw_base64())
    monkeypatch.delenv("BURNBAR_RELAY_E2E", raising=False)
    monkeypatch.delenv("BURNBAR_ALLOW_PLAINTEXT", raising=False)
    cfg = PlatformConfig(enabled=True, extra={"access_token": "tok", "home_channel": "burnbar:home"})

    refusing = BurnBarAdapter(cfg)
    refusing._client = _RecordingClient(post_responses={"/messages": _FakeResponse({"message": {"id": "m1"}})})
    res = await refusing.send("burnbar:home", "would-be plaintext")
    assert res.success is False
    assert "BURNBAR_ALLOW_PLAINTEXT" in (res.error or "")
    assert refusing._client.posts == []  # nothing left the process in plaintext

    monkeypatch.setenv("BURNBAR_ALLOW_PLAINTEXT", "1")
    allowing = BurnBarAdapter(cfg)
    allowing._client = _RecordingClient(post_responses={"/messages": _FakeResponse({"message": {"id": "m2"}})})
    res2 = await allowing.send("burnbar:home", "explicit plaintext")
    assert res2.success is True
    _, body = allowing._client.posts[-1]
    assert body["text"] == "explicit plaintext"


@requires_relay
@pytest.mark.asyncio
async def test_e2e_capable_agent_refuses_inbound_plaintext_without_optin(monkeypatch, tmp_path):
    """The INBOUND path is symmetric with the send-side ``must_seal``.

    An agent holding a relay identity but not E2E-paired must DROP a relay-supplied
    plaintext event (the relay could otherwise drive the agent with injected
    commands), and only process it when the operator explicitly opts into the legacy
    plaintext path with BURNBAR_ALLOW_PLAINTEXT=1.
    """
    monkeypatch.setattr(_burnbar, "CURSOR_FILE", tmp_path / "cursor.json")
    monkeypatch.setattr(_burnbar, "REPLAY_LEDGER_FILE", tmp_path / "replay.json")
    monkeypatch.setenv("BURNBAR_RELAY_PRIVATE_KEY", relay_e2ee.generate_private_key().raw_base64())
    monkeypatch.delenv("BURNBAR_RELAY_E2E", raising=False)
    monkeypatch.delenv("BURNBAR_ALLOW_PLAINTEXT", raising=False)
    cfg = PlatformConfig(enabled=True, extra={"access_token": "tok", "home_channel": "burnbar:home"})
    injected = {"id": "evt_plaintext_in", "destinationId": "burnbar:home", "text": "injected by relay"}

    refusing = BurnBarAdapter(cfg)
    received: list = []

    async def capture(event):
        received.append(event)

    refusing.handle_message = capture
    await refusing._handle_burnbar_event(dict(injected))
    assert received == []  # relay-supplied plaintext was dropped, not executed

    monkeypatch.setenv("BURNBAR_ALLOW_PLAINTEXT", "1")
    allowing = BurnBarAdapter(cfg)
    allowed: list = []

    async def capture_allowed(event):
        allowed.append(event)

    allowing.handle_message = capture_allowed
    await allowing._handle_burnbar_event(dict(injected))
    assert len(allowed) == 1  # explicit opt-in still processes the legacy plaintext path
    assert allowed[0].text == "injected by relay"


@requires_relay
@pytest.mark.asyncio
async def test_gateway_event_vector_passes_production_open_path(monkeypatch, tmp_path):
    """The committed gateway event vector now carries the strict
    schema (authenticated destinationId + replayCounter) and is accepted by the full
    production ``_handle_burnbar_event`` path, not merely the direct crypto open.

    Before the schema refresh the same vector was dropped at the destinationId /
    replayCounter gate, so this is the regression guard proving the committed
    fixture matches the ENFORCED event schema (not just the crypto envelope).
    """
    fixture_path = os.path.join(os.path.dirname(__file__), "fixtures", "HermesGatewayWireVector.json")
    with open(fixture_path, "r", encoding="utf-8") as handle:
        event = json.load(handle)["event"]

    monkeypatch.setattr(_burnbar, "CURSOR_FILE", tmp_path / "cursor.json")
    monkeypatch.setattr(_burnbar, "REPLAY_LEDGER_FILE", tmp_path / "replay.json")
    monkeypatch.delenv("BURNBAR_RELAY_E2E", raising=False)
    monkeypatch.delenv("BURNBAR_RELAY_PEER_PUBLIC_KEY", raising=False)
    cfg = PlatformConfig(enabled=True, extra={"access_token": "tok", "home_channel": "burnbar:home"})
    adapter = BurnBarAdapter(cfg)
    # Pin the adapter to the vector's identities: agent = recipient, phone = sender.
    adapter._relay_identity = relay_e2ee.AgentRelayIdentity(
        relay_e2ee.RelayPrivateKey.from_base64(event["recipientPrivateKey"])
    )
    adapter._relay_e2e_enabled = True
    adapter._relay_e2e_config_error = None
    adapter._peer_public_key = event["senderPublicKey"]
    adapter._relay_uid = event["uid"]
    adapter._relay_client_id = event["clientId"]
    adapter._relay_uid_pinned = True
    adapter._relay_client_id_pinned = True
    adapter._load_replay_ledger(reset=True)

    received: list = []

    async def capture(ev):
        received.append(ev)

    adapter.handle_message = capture
    await adapter._handle_burnbar_event({
        "id": event["eventId"],
        "destinationId": "burnbar:home",
        "senderPublicKey": event["senderPublicKey"],
        "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
        "relayEnvelope": {
            "eventId": event["eventId"],
            "payloadCiphertext": event["payloadCiphertext"],
            "wrappedKey": event["wrappedKey"],
            "senderPublicKey": event["senderPublicKey"],
            "relayEncryption": _burnbar.RELAY_ENCRYPTION,
            "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
        },
    })
    assert len(received) == 1  # accepted by the enforced path, not dropped
    assert received[0].text == "open the BurnBar gateway"
    # The authenticated replayCounter (1) advanced the persisted high-water mark.
    assert adapter._event_replay_high_water == 1
    # Hardening: an E2E-authenticated event must not carry the relay ciphertext
    # envelope downstream into the trajectory, only routing-relevant fields. This
    # guards the raw_message sanitization (the relay already holds these blobs;
    # they must not bloat session logs / exports).
    raw = received[0].raw_message
    assert isinstance(raw, dict)
    assert raw.get("id") == event["eventId"]
    assert raw.get("destinationId") == "burnbar:home"
    for leaked in ("payloadCiphertext", "wrappedKey", "relayEnvelope", "senderPublicKey"):
        assert leaked not in raw, f"sealed event raw_message leaked {leaked}"


@requires_relay
@pytest.mark.asyncio
async def test_refuses_v1_wrapped_event_on_e2e_link(monkeypatch, tmp_path):
    """A v1 wrap (no sender leg) + omitted relayKeyVersion on an E2E link is
    refused at the v2-only open gate. The library still exposes v1, so this guards
    against regressing the gate."""
    phone_priv = relay_e2ee.generate_private_key()
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=phone_priv.public_key_base64())
    agent_pub = adapter._relay_public_key_base64()
    event_id = "evt_v1"
    payload_ct = relay_e2ee.seal_to_base64(
        json.dumps({"text": "v1"}).encode(), relay_e2ee.generate_symmetric_key(),
        _burnbar._gateway_event_aad("uid-1", "client-1", event_id),
    )
    # v1 wrap: NO sender_private (anonymous); envelope omits relayKeyVersion.
    wrapped = relay_e2ee.wrap_symmetric_key(
        relay_e2ee.generate_symmetric_key(), agent_pub,
        _burnbar._gateway_event_key_aad("uid-1", "client-1", event_id),
    )
    received = []

    async def capture(event):
        received.append(event)

    adapter.handle_message = capture
    await adapter._handle_burnbar_event({
        "id": event_id, "destinationId": "burnbar:home",
        "relayEnvelope": {"payloadCiphertext": payload_ct, "wrappedKey": wrapped},
    })
    assert received == []  # refused at the v2-only gate


# --- Post-review remediation (oversight / approval / replay / routing) ----------


@pytest.mark.asyncio
async def test_e2e_link_ignores_relay_oversight_mode_flip(tmp_path, monkeypatch):
    """On E2E-paired links /state oversightMode is not authoritative (relay forgery)."""
    monkeypatch.setenv("BURNBAR_OVERSIGHT_MODE", "supervised")
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path)
    adapter._client = _RecordingClient(
        get_responses={"/state": _FakeResponse({"oversightMode": "autonomous"})}
    )
    await adapter._refresh_oversight_mode()
    assert adapter._oversight_mode == "supervised"


@requires_relay
@pytest.mark.asyncio
async def test_e2e_approval_poll_ignored_sealed_decision_applies(monkeypatch, tmp_path):
    """E2E links must not trust /approvals poll; only sealed approval_decision events."""
    phone_priv = relay_e2ee.generate_private_key()
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=phone_priv.public_key_base64())
    agent_pub = adapter._relay_public_key_base64()
    adapter._oversight_mode = "supervised"
    adapter._pending_confirms["act_sealed"] = {
        "session_key": "sk",
        "chat_id": "burnbar:home",
        "metadata": None,
    }
    resolved = []

    async def fake_resolve(session_key, confirm_id, choice, chat_id, metadata, fallback=None):
        resolved.append((confirm_id, choice))

    adapter._resolve_slash_confirm = fake_resolve
    adapter._client = _RecordingClient(
        get_responses={
            "/approvals": _FakeResponse({"approval": {"status": "approved"}}),
        }
    )
    await adapter._resolve_pending_confirms()
    assert resolved == []  # forged poll ignored on E2E

    event_id = "evt_approval"
    payload_aad = _burnbar._gateway_event_aad("uid-1", "client-1", event_id)
    key_aad = _burnbar._gateway_event_key_aad("uid-1", "client-1", event_id)
    sym = relay_e2ee.generate_symmetric_key()
    payload_ct = relay_e2ee.seal_to_base64(
        json.dumps(
            {
                "kind": "approval_decision",
                "actionId": "act_sealed",
                "choice": "approve",
                "destinationId": "burnbar:home",
                "senderId": "burnbar-ios",
                "replayCounter": 1,
            }
        ).encode(),
        sym,
        payload_aad,
    )
    wrapped = relay_e2ee.wrap_symmetric_key(sym, agent_pub, key_aad, sender_private=phone_priv)
    await adapter._handle_burnbar_event(
        {
            "id": event_id,
            "destinationId": "burnbar:home",
            "senderPublicKey": phone_priv.public_key_base64(),
            "relayEnvelope": {
                "payloadCiphertext": payload_ct,
                "wrappedKey": wrapped,
                "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
                "senderPublicKey": phone_priv.public_key_base64(),
            },
        }
    )
    assert resolved == [("act_sealed", "once")]


@requires_relay
def test_replay_ledger_survives_adapter_restart(monkeypatch, tmp_path):
    """Persisted replay ids block redelivery after a new adapter instance."""
    replay_file = tmp_path / "replay.json"
    monkeypatch.setattr(_burnbar, "REPLAY_LEDGER_FILE", replay_file)
    adapter1, _ = _e2e_adapter(monkeypatch, tmp_path)
    adapter1._record_event("evt_persisted")
    adapter2, _ = _e2e_adapter(monkeypatch, tmp_path)
    assert adapter2._is_event_seen("evt_persisted") is True


@requires_relay
@pytest.mark.asyncio
async def test_persistent_replay_ledger_blocks_sealed_event_after_restart(monkeypatch, tmp_path):
    """A real authenticated event is not re-run after gateway restart."""
    phone_priv = relay_e2ee.generate_private_key()
    phone_pub = phone_priv.public_key_base64()
    replay_file = tmp_path / "replay.json"
    monkeypatch.setattr(_burnbar, "REPLAY_LEDGER_FILE", replay_file)

    adapter1, agent_priv = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=phone_pub)
    agent_pub = adapter1._relay_public_key_base64()
    event_id = "evt_restart_replay"
    sym = relay_e2ee.generate_symmetric_key()
    payload_ct = relay_e2ee.seal_to_base64(
        json.dumps({"text": "run once", "destinationId": "burnbar:home", "replayCounter": 1}).encode(),
        sym,
        _burnbar._gateway_event_aad("uid-1", "client-1", event_id),
    )
    wrapped = relay_e2ee.wrap_symmetric_key(
        sym,
        agent_pub,
        _burnbar._gateway_event_key_aad("uid-1", "client-1", event_id),
        sender_private=phone_priv,
    )
    raw = {
        "id": event_id,
        "destinationId": "burnbar:home",
        "senderPublicKey": phone_pub,
        "relayEnvelope": {
            "payloadCiphertext": payload_ct,
            "wrappedKey": wrapped,
            "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
            "senderPublicKey": phone_pub,
        },
    }

    first_received = []
    adapter1.handle_message = lambda e: first_received.append(e) or _noop()
    await adapter1._handle_burnbar_event(dict(raw))
    assert len(first_received) == 1

    adapter2, _ = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=phone_pub)
    adapter2._relay_identity = relay_e2ee.AgentRelayIdentity(agent_priv)
    second_received = []
    adapter2.handle_message = lambda e: second_received.append(e) or _noop()
    await adapter2._handle_burnbar_event(dict(raw))
    assert second_received == []


@requires_relay
@pytest.mark.asyncio
async def test_attachment_init_id_mismatch_fails_closed(monkeypatch, tmp_path):
    """Server must adopt the AAD-bound attachmentId."""
    phone_priv = relay_e2ee.generate_private_key()
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=phone_priv.public_key_base64())
    sealer = adapter._sealer
    file_path = tmp_path / "secret.bin"
    file_path.write_bytes(b"payload")
    relay_envelope, _body = sealer.seal_attachment(
        destination_id="burnbar:home", file_path=file_path, content_type="application/octet-stream"
    )
    client = _RecordingClient(
        post_responses={
            "/attachments/init": _FakeResponse(
                {"attachment": {"id": "server_minted_wrong"}, "uploadURL": "https://upload"}
            )
        }
    )
    with pytest.raises(_burnbar._RelayPlaintextRefused):
        await _burnbar._init_attachment(
            client,
            api_base=adapter._api_base,
            token=adapter._token,
            destination_id="burnbar:home",
            file_path=file_path,
            content_type="application/octet-stream",
            relay_envelope=relay_envelope,
            byte_count_override=len(_body),
        )


@requires_relay
@pytest.mark.asyncio
async def test_sealed_attachment_id_mismatch_send_path_does_not_upload(monkeypatch, tmp_path):
    """If the server does not adopt the sealed attachmentId, no bytes are uploaded."""
    phone_priv = relay_e2ee.generate_private_key()
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=phone_priv.public_key_base64())
    file_path = tmp_path / "secret.txt"
    file_path.write_text("classified")
    adapter._client = _RecordingClient(
        post_responses={
            "/attachments/init": _FakeResponse(
                {"attachment": {"id": "server_minted_wrong"}, "uploadURL": "https://upload"}
            ),
            "/messages": _FakeResponse({"message": {"id": "should_not_post"}}),
        }
    )

    result = await adapter.send_document("burnbar:home", str(file_path), caption="nope")
    assert result.success is False
    assert adapter._client.puts == []
    assert all(not url.endswith("/messages") for (url, _body) in adapter._client.posts)


@requires_relay
@pytest.mark.asyncio
async def test_sealed_oversight_mode_event_updates_e2e_mode(monkeypatch, tmp_path):
    """On E2E links, oversight mode changes come from sealed phone events."""
    saved = {}
    import hermes_cli.config as _cfg

    monkeypatch.setattr(_cfg, "save_env_value", lambda key, value: saved.__setitem__(key, value), raising=False)
    phone_priv = relay_e2ee.generate_private_key()
    phone_pub = phone_priv.public_key_base64()
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=phone_pub)
    agent_pub = adapter._relay_public_key_base64()
    assert adapter._oversight_mode == "supervised"

    event_id = "evt_oversight"
    sym = relay_e2ee.generate_symmetric_key()
    payload_ct = relay_e2ee.seal_to_base64(
        json.dumps(
            {
                "kind": "oversight_mode",
                "mode": "autonomous",
                "destinationId": "burnbar:home",
                "replayCounter": 1,
            }
        ).encode(),
        sym,
        _burnbar._gateway_event_aad("uid-1", "client-1", event_id),
    )
    wrapped = relay_e2ee.wrap_symmetric_key(
        sym,
        agent_pub,
        _burnbar._gateway_event_key_aad("uid-1", "client-1", event_id),
        sender_private=phone_priv,
    )
    await adapter._handle_burnbar_event(
        {
            "id": event_id,
            "destinationId": "burnbar:home",
            "senderPublicKey": phone_pub,
            "relayEnvelope": {
                "payloadCiphertext": payload_ct,
                "wrappedKey": wrapped,
                "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
                "senderPublicKey": phone_pub,
            },
        }
    )
    assert adapter._oversight_mode == "autonomous"
    assert saved[_burnbar.OVERSIGHT_MODE_ENV] == "autonomous"


@requires_relay
@pytest.mark.asyncio
async def test_sealed_destination_wins_over_relay_top_level(monkeypatch, tmp_path):
    """Authenticated payload destinationId wins over relay-controlled top-level routing."""
    phone_priv = relay_e2ee.generate_private_key()
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=phone_priv.public_key_base64())
    agent_pub = adapter._relay_public_key_base64()
    event_id = "evt_route"
    sym = relay_e2ee.generate_symmetric_key()
    payload_ct = relay_e2ee.seal_to_base64(
        json.dumps(
            {
                "text": "hello",
                "destinationId": "burnbar:home",
                "senderId": "u",
                "replayCounter": 1,
            }
        ).encode(),
        sym,
        _burnbar._gateway_event_aad("uid-1", "client-1", event_id),
    )
    wrapped = relay_e2ee.wrap_symmetric_key(
        sym,
        agent_pub,
        _burnbar._gateway_event_key_aad("uid-1", "client-1", event_id),
        sender_private=phone_priv,
    )
    received = []
    adapter.handle_message = lambda e: received.append(e) or _noop()
    await adapter._handle_burnbar_event(
        {
            "id": event_id,
            "destinationId": "burnbar:other",
            "relayEnvelope": {
                "payloadCiphertext": payload_ct,
                "wrappedKey": wrapped,
                "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
                "senderPublicKey": phone_priv.public_key_base64(),
            },
        }
    )
    assert len(received) == 1
    assert received[0].source.chat_id == "burnbar:home"


@requires_relay
@pytest.mark.asyncio
async def test_e2e_sealed_event_requires_authenticated_destination(monkeypatch, tmp_path):
    """E2E events without a sealed destinationId are dropped before side effects."""
    phone_priv = relay_e2ee.generate_private_key()
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=phone_priv.public_key_base64())
    agent_pub = adapter._relay_public_key_base64()
    event_id = "evt_missing_dest"
    sym = relay_e2ee.generate_symmetric_key()
    payload_ct = relay_e2ee.seal_to_base64(
        json.dumps({"text": "hello", "senderId": "u", "replayCounter": 1}).encode(),
        sym,
        _burnbar._gateway_event_aad("uid-1", "client-1", event_id),
    )
    wrapped = relay_e2ee.wrap_symmetric_key(
        sym,
        agent_pub,
        _burnbar._gateway_event_key_aad("uid-1", "client-1", event_id),
        sender_private=phone_priv,
    )
    received = []
    adapter.handle_message = lambda e: received.append(e) or _noop()
    await adapter._handle_burnbar_event(
        {
            "id": event_id,
            "destinationId": "burnbar:home",
            "relayEnvelope": {
                "payloadCiphertext": payload_ct,
                "wrappedKey": wrapped,
                "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
                "senderPublicKey": phone_priv.public_key_base64(),
            },
        }
    )
    assert received == []
    assert adapter._event_replay_key(event_id) not in adapter._seen_event_ids


@requires_relay
@pytest.mark.asyncio
async def test_relay_top_level_model_switch_spoof_cannot_override_sealed_chat(monkeypatch, tmp_path):
    """Relay-controlled kind/modelId cannot turn a sealed chat event into a model switch."""
    phone_priv = relay_e2ee.generate_private_key()
    phone_pub = phone_priv.public_key_base64()
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=phone_pub)
    agent_pub = adapter._relay_public_key_base64()
    adapter._publish_runtime_status = lambda *a, **k: pytest.fail("model switch side effect should not run")

    event_id = "evt_kind_spoof"
    sym = relay_e2ee.generate_symmetric_key()
    payload_ct = relay_e2ee.seal_to_base64(
        json.dumps({"text": "normal chat", "destinationId": "burnbar:home", "replayCounter": 1}).encode(),
        sym,
        _burnbar._gateway_event_aad("uid-1", "client-1", event_id),
    )
    wrapped = relay_e2ee.wrap_symmetric_key(
        sym,
        agent_pub,
        _burnbar._gateway_event_key_aad("uid-1", "client-1", event_id),
        sender_private=phone_priv,
    )
    received = []
    adapter.handle_message = lambda e: received.append(e) or _noop()
    await adapter._handle_burnbar_event(
        {
            "id": event_id,
            "kind": "model_switch",
            "modelId": "anthropic/claude",
            "destinationId": "burnbar:home",
            "relayEnvelope": {
                "payloadCiphertext": payload_ct,
                "wrappedKey": wrapped,
                "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
                "senderPublicKey": phone_pub,
            },
        }
    )

    assert len(received) == 1
    assert received[0].text == "normal chat"


@requires_relay
@pytest.mark.asyncio
async def test_sealed_approval_wrong_destination_does_not_resolve_or_pop(monkeypatch, tmp_path):
    """A valid phone-signed approval for the wrong destination cannot authorize this gate."""
    phone_priv = relay_e2ee.generate_private_key()
    phone_pub = phone_priv.public_key_base64()
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=phone_pub)
    agent_pub = adapter._relay_public_key_base64()
    adapter._pending_confirms["act_dest"] = {
        "session_key": "sk",
        "chat_id": "burnbar:home",
        "metadata": None,
    }
    resolved = []
    adapter._resolve_slash_confirm = lambda *args, **kwargs: resolved.append(args) or _noop()

    event_id = "evt_approval_wrong_dest"
    sym = relay_e2ee.generate_symmetric_key()
    payload_ct = relay_e2ee.seal_to_base64(
        json.dumps(
            {
                "kind": "approval_decision",
                "actionId": "act_dest",
                "choice": "approve",
                "destinationId": "burnbar:other",
                "replayCounter": 1,
            }
        ).encode(),
        sym,
        _burnbar._gateway_event_aad("uid-1", "client-1", event_id),
    )
    wrapped = relay_e2ee.wrap_symmetric_key(
        sym,
        agent_pub,
        _burnbar._gateway_event_key_aad("uid-1", "client-1", event_id),
        sender_private=phone_priv,
    )
    await adapter._handle_burnbar_event(
        {
            "id": event_id,
            "destinationId": "burnbar:home",
            "senderPublicKey": phone_pub,
            "relayEnvelope": {
                "payloadCiphertext": payload_ct,
                "wrappedKey": wrapped,
                "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
                "senderPublicKey": phone_pub,
            },
        }
    )

    assert resolved == []
    assert "act_dest" in adapter._pending_confirms


@requires_relay
@pytest.mark.asyncio
async def test_e2e_replay_persist_failure_fails_closed_before_dispatch(monkeypatch, tmp_path):
    """If the durable replay ledger cannot be written, E2E drops before side effects."""
    phone_priv = relay_e2ee.generate_private_key()
    phone_pub = phone_priv.public_key_base64()
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=phone_pub)
    agent_pub = adapter._relay_public_key_base64()
    monkeypatch.setattr(
        adapter,
        "_persist_replay_ledger",
        lambda: (_ for _ in ()).throw(RuntimeError("read-only replay ledger")),
    )

    event_id = "evt_replay_persist_fail"
    sym = relay_e2ee.generate_symmetric_key()
    payload_ct = relay_e2ee.seal_to_base64(
        json.dumps(
            {"text": "must not dispatch", "destinationId": "burnbar:home", "replayCounter": 1}
        ).encode(),
        sym,
        _burnbar._gateway_event_aad("uid-1", "client-1", event_id),
    )
    wrapped = relay_e2ee.wrap_symmetric_key(
        sym,
        agent_pub,
        _burnbar._gateway_event_key_aad("uid-1", "client-1", event_id),
        sender_private=phone_priv,
    )
    received = []
    adapter.handle_message = lambda e: received.append(e) or _noop()
    await adapter._handle_burnbar_event(
        {
            "id": event_id,
            "destinationId": "burnbar:home",
            "senderPublicKey": phone_pub,
            "relayEnvelope": {
                "payloadCiphertext": payload_ct,
                "wrappedKey": wrapped,
                "relayKeyVersion": _burnbar.GATEWAY_RELAY_KEY_VERSION,
                "senderPublicKey": phone_pub,
            },
        }
    )

    assert received == []
