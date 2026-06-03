"""Tests for the BurnBar Cloud platform-plugin adapter.

Covers the messaging surface (registration, config, inbound mapping, send,
attachments, cursor, oversight/runtime-status) and the end-to-end relay
encryption added in PR2: a real seal -> open round-trip against
``gateway.crypto.relay_e2ee`` proving the agent seals replies to the phone's
relay public key, opens phone-sealed events with its own key, and refuses
plaintext once the link is E2E-paired.
"""

from __future__ import annotations

import json
import os
from unittest.mock import MagicMock

import pytest

from gateway.config import PlatformConfig
from tests.gateway._plugin_adapter_loader import load_plugin_adapter

_burnbar = load_plugin_adapter("burnbar")

BurnBarAdapter = _burnbar.BurnBarAdapter
check_requirements = _burnbar.check_requirements
validate_config = _burnbar.validate_config
is_connected = _burnbar.is_connected
_env_enablement = _burnbar._env_enablement
_apply_yaml_config = _burnbar._apply_yaml_config

try:
    from gateway.crypto import relay_e2ee

    RELAY_CRYPTO_AVAILABLE = True
except Exception:  # pragma: no cover - cryptography missing in CI slice.
    relay_e2ee = None
    RELAY_CRYPTO_AVAILABLE = False

requires_relay = pytest.mark.skipif(
    not RELAY_CRYPTO_AVAILABLE, reason="cryptography / relay_e2ee unavailable"
)


# ---------------------------------------------------------------------------
# httpx test doubles
# ---------------------------------------------------------------------------
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
    """Minimal async httpx.AsyncClient stand-in that records calls.

    ``post_responses`` maps a URL suffix to either a response or a callable
    ``(json_body) -> _FakeResponse`` so a test can both assert on the request
    body and shape the reply.
    """

    def __init__(self, *, post_responses=None, put_response=None, get_responses=None):
        self.post_responses = post_responses or {}
        self.put_response = put_response or _FakeResponse()
        self.get_responses = get_responses or {}
        self.posts = []  # list of (url, json)
        self.puts = []  # list of (url, content, headers)
        self.gets = []  # list of (url, params)

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


# ---------------------------------------------------------------------------
# Registration / config (PR1)
# ---------------------------------------------------------------------------
def test_platform_enum_resolves_via_plugin_scan():
    from gateway.config import Platform

    platform = Platform("burnbar")
    assert platform.value == "burnbar"
    assert Platform("burnbar") is platform


def test_check_requirements_requires_httpx_and_token(monkeypatch):
    monkeypatch.setattr(_burnbar, "HTTPX_AVAILABLE", True)
    monkeypatch.delenv("BURNBAR_ACCESS_TOKEN", raising=False)
    assert check_requirements() is False

    monkeypatch.setenv("BURNBAR_ACCESS_TOKEN", "tok")
    assert check_requirements() is True

    monkeypatch.setattr(_burnbar, "HTTPX_AVAILABLE", False)
    assert check_requirements() is False


def test_validate_config_and_is_connected_use_extra_or_env(monkeypatch):
    monkeypatch.delenv("BURNBAR_ACCESS_TOKEN", raising=False)
    empty = PlatformConfig(enabled=True, extra={})
    configured = PlatformConfig(enabled=True, extra={"access_token": "tok"})

    assert validate_config(empty) is False
    assert is_connected(empty) is False
    assert validate_config(configured) is True
    assert is_connected(configured) is True

    monkeypatch.setenv("BURNBAR_ACCESS_TOKEN", "env-token")
    assert validate_config(empty) is True
    assert is_connected(empty) is True


def test_env_enablement_seeds_api_token_and_home_channel(monkeypatch):
    monkeypatch.setenv("BURNBAR_ACCESS_TOKEN", "tok")
    monkeypatch.setenv("BURNBAR_API_BASE_URL", "https://example.com/v1/hermes-gateway/")
    monkeypatch.setenv("BURNBAR_HOME_CHANNEL", "burnbar:phone")
    monkeypatch.setenv("BURNBAR_HOME_CHANNEL_NAME", "Phone")

    assert _env_enablement() == {
        "api_base_url": "https://example.com/v1/hermes-gateway",
        "access_token": "tok",
        "home_channel": {"chat_id": "burnbar:phone", "name": "Phone"},
    }


def test_env_enablement_none_when_token_missing(monkeypatch):
    monkeypatch.delenv("BURNBAR_ACCESS_TOKEN", raising=False)
    assert _env_enablement() is None


def test_apply_yaml_config_preserves_env_precedence(monkeypatch):
    monkeypatch.setenv("BURNBAR_ACCESS_TOKEN", "env-token")
    platform_cfg = {"extra": {"existing": "value"}}

    extra = _apply_yaml_config(
        {
            "api_base_url": "https://api.example/v1/hermes-gateway",
            "access_token": "yaml-token",
            "home_channel": "burnbar:home",
        },
        platform_cfg,
    )

    assert extra == {
        "existing": "value",
        "api_base_url": "https://api.example/v1/hermes-gateway",
        "access_token": "yaml-token",
        "home_channel": "burnbar:home",
    }
    assert os.environ["BURNBAR_ACCESS_TOKEN"] == "env-token"
    assert os.environ["BURNBAR_API_BASE_URL"] == "https://api.example/v1/hermes-gateway"


def test_adapter_identity_and_defaults(monkeypatch):
    from gateway.config import Platform

    monkeypatch.delenv("BURNBAR_API_BASE_URL", raising=False)
    monkeypatch.delenv("BURNBAR_RELAY_E2E", raising=False)
    cfg = PlatformConfig(enabled=True, extra={"access_token": "tok", "home_channel": "burnbar:phone"})
    adapter = BurnBarAdapter(cfg)

    assert adapter.platform is Platform("burnbar")
    assert adapter._api_base == _burnbar.DEFAULT_API_BASE_URL
    assert adapter._token == "tok"
    assert adapter._home_channel == "burnbar:phone"
    # Legacy default: no E2E negotiated -> plaintext path stays available.
    assert adapter._relay_e2e_enabled is False


def test_register_shape_matches_platform_registry():
    ctx = MagicMock()

    _burnbar.register(ctx)

    ctx.register_platform.assert_called_once()
    kwargs = ctx.register_platform.call_args.kwargs
    assert kwargs["name"] == "burnbar"
    assert kwargs["label"] == "BurnBar Cloud"
    assert kwargs["required_env"] == ["BURNBAR_ACCESS_TOKEN"]
    assert kwargs["allowed_users_env"] == "BURNBAR_ALLOWED_USERS"
    assert kwargs["allow_all_env"] == "BURNBAR_ALLOW_ALL_USERS"
    assert kwargs["cron_deliver_env_var"] == "BURNBAR_HOME_CHANNEL"
    assert kwargs["max_message_length"] == _burnbar.MAX_MESSAGE_LENGTH
    assert callable(kwargs["adapter_factory"])
    assert callable(kwargs["setup_fn"])
    assert callable(kwargs["standalone_sender_fn"])
    assert "supports_media" not in kwargs


# ---------------------------------------------------------------------------
# Inbound mapping (legacy plaintext) + cursor (PR1)
# ---------------------------------------------------------------------------
def _legacy_adapter(monkeypatch, tmp_path):
    monkeypatch.setattr(_burnbar, "CURSOR_FILE", tmp_path / "cursor.json")
    monkeypatch.delenv("BURNBAR_RELAY_E2E", raising=False)
    cfg = PlatformConfig(enabled=True, extra={"access_token": "tok", "home_channel": "burnbar:home"})
    return BurnBarAdapter(cfg)


@pytest.mark.asyncio
async def test_inbound_event_maps_to_gateway_message_event(tmp_path, monkeypatch):
    adapter = _legacy_adapter(monkeypatch, tmp_path)
    received = []

    async def capture(event):
        received.append(event)

    adapter.handle_message = capture
    await adapter._handle_burnbar_event(
        {
            "id": "evt_1",
            "destinationId": "burnbar:home",
            "senderId": "sender_1",
            "senderDisplayName": "Alberto",
            "threadId": "thread_1",
            "text": "hello hermes",
        }
    )

    assert len(received) == 1
    event = received[0]
    assert event.text == "hello hermes"
    assert event.message_id == "evt_1"
    assert event.source.platform.value == "burnbar"
    assert event.source.chat_id == "burnbar:home"
    assert event.source.user_id == "sender_1"
    assert event.source.user_name == "Alberto"
    assert event.source.thread_id == "thread_1"


@pytest.mark.asyncio
async def test_model_switch_event_synthesizes_model_command(tmp_path, monkeypatch):
    adapter = _legacy_adapter(monkeypatch, tmp_path)
    received = []

    async def capture(event):
        received.append(event)

    adapter.handle_message = capture
    # _publish_runtime_status would need a client; stub it out.
    adapter._publish_runtime_status = lambda *a, **k: _noop()
    await adapter._handle_burnbar_event(
        {"id": "evt_m", "kind": "model_switch", "modelId": "anthropic/claude", "destinationId": "burnbar:home"}
    )
    assert received and received[0].text == "/model anthropic/claude"


async def _noop():
    return None


def test_cursor_round_trip(tmp_path, monkeypatch):
    monkeypatch.setattr(_burnbar, "CURSOR_FILE", tmp_path / "cursor.json")
    assert _burnbar._read_cursor() == 0
    _burnbar._write_cursor(42)
    assert _burnbar._read_cursor() == 42
    # Non-positive / corrupt values floor to 0.
    _burnbar._write_cursor(0)
    assert _burnbar._read_cursor() == 0


# ---------------------------------------------------------------------------
# Send happy / error + attachment (legacy plaintext path)
# ---------------------------------------------------------------------------
@pytest.mark.asyncio
async def test_send_happy_path_posts_plaintext_when_legacy(tmp_path, monkeypatch):
    adapter = _legacy_adapter(monkeypatch, tmp_path)
    client = _RecordingClient(
        post_responses={"/messages": _FakeResponse({"message": {"id": "msg_1"}})}
    )
    adapter._client = client

    result = await adapter.send("burnbar:home", "all done", reply_to="evt_9")

    assert result.success is True
    assert result.message_id == "msg_1"
    url, body = client.posts[-1]
    assert url.endswith("/messages")
    assert body["text"] == "all done"
    assert body["replyToEventId"] == "evt_9"
    assert "relayEnvelope" not in body


@pytest.mark.asyncio
async def test_send_error_returns_failure(tmp_path, monkeypatch):
    adapter = _legacy_adapter(monkeypatch, tmp_path)
    client = _RecordingClient(post_responses={"/messages": _FakeResponse(status_code=500)})
    adapter._client = client

    result = await adapter.send("burnbar:home", "boom")
    assert result.success is False
    assert result.error


@pytest.mark.asyncio
async def test_send_local_file_inits_uploads_and_posts(tmp_path, monkeypatch):
    adapter = _legacy_adapter(monkeypatch, tmp_path)
    f = tmp_path / "report.txt"
    f.write_text("payload-bytes")
    client = _RecordingClient(
        post_responses={
            "/attachments/init": _FakeResponse(
                {"attachment": {"id": "att_1"}, "uploadURL": "https://signed.example/put"}
            ),
            "/messages": _FakeResponse({"message": {"id": "msg_att"}}),
        }
    )
    adapter._client = client

    result = await adapter.send_document("burnbar:home", str(f), caption="see attached")

    assert result.success is True
    assert result.message_id == "msg_att"
    # init carried plaintext fileName on the legacy path.
    init_url, init_body = next((u, b) for (u, b) in client.posts if u.endswith("/attachments/init"))
    assert init_body["fileName"] == "report.txt"
    # body uploaded verbatim (no sealing) to the signed URL.
    assert client.puts and client.puts[0][1] == b"payload-bytes"
    # the message references the attachment id.
    _, msg_body = next((u, b) for (u, b) in client.posts if u.endswith("/messages"))
    assert msg_body["attachmentIds"] == ["att_1"]


# ---------------------------------------------------------------------------
# Oversight + runtime status (PR1 reconcile)
# ---------------------------------------------------------------------------
@pytest.mark.asyncio
async def test_refresh_oversight_mode_reads_state(tmp_path, monkeypatch):
    adapter = _legacy_adapter(monkeypatch, tmp_path)
    adapter._client = _RecordingClient(
        get_responses={"/state": _FakeResponse({"oversightMode": "autonomous"})}
    )
    assert adapter._oversight_mode == "supervised"
    await adapter._refresh_oversight_mode()
    assert adapter._oversight_mode == "autonomous"


@pytest.mark.asyncio
async def test_autonomous_oversight_auto_approves(tmp_path, monkeypatch):
    adapter = _legacy_adapter(monkeypatch, tmp_path)
    adapter._client = _RecordingClient()
    adapter._oversight_mode = "autonomous"
    resolved = {}

    async def fake_resolve(session_key, confirm_id, choice, chat_id, metadata, fallback=None):
        resolved["choice"] = choice

    adapter._resolve_slash_confirm = fake_resolve
    result = await adapter.send_slash_confirm("burnbar:home", "Run tool", "details", "sk", "cid")
    assert result.success is True
    assert resolved["choice"] == "once"


def test_runtime_status_payload_shape(monkeypatch):
    # Force the inventory import to fail -> empty payload, but still importable.
    body = _burnbar._runtime_status_payload()
    assert isinstance(body, dict)
    # When inventory is available it has modelOptions; when not, it's {}.
    if body:
        assert "modelOptions" in body


# ---------------------------------------------------------------------------
# E2E relay (PR2): seal -> open round trip, refuse-plaintext
# ---------------------------------------------------------------------------
def _e2e_adapter(monkeypatch, tmp_path, *, peer_public_key=None):
    """Build an adapter forced into E2E mode with an injected agent identity."""
    monkeypatch.setattr(_burnbar, "CURSOR_FILE", tmp_path / "cursor.json")
    monkeypatch.delenv("BURNBAR_RELAY_E2E", raising=False)
    monkeypatch.delenv("BURNBAR_RELAY_PEER_PUBLIC_KEY", raising=False)
    cfg = PlatformConfig(enabled=True, extra={"access_token": "tok", "home_channel": "burnbar:home"})
    adapter = BurnBarAdapter(cfg)
    # Inject a deterministic agent relay identity (avoid touching ~/.hermes/.env).
    agent_priv = relay_e2ee.generate_private_key()
    adapter._relay_identity = relay_e2ee.AgentRelayIdentity(agent_priv)
    adapter._relay_e2e_enabled = True
    adapter._relay_uid = "uid-1"
    adapter._relay_client_id = "client-1"
    if peer_public_key:
        adapter._peer_public_key = peer_public_key
    return adapter, agent_priv


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
    assert env["relayKeyVersion"] == _burnbar.RELAY_KEY_VERSION
    assert body["relayEncryption"] == _burnbar.RELAY_ENCRYPTION

    # The phone unwraps the key + opens the payload using the SAME gateway AAD.
    message_id = env["messageId"]
    aad = _burnbar._gateway_message_aad("uid-1", "client-1", message_id)
    sym = relay_e2ee.unwrap_symmetric_key(env["wrappedKey"], phone_priv, aad)
    opened = json.loads(relay_e2ee.open_base64(env["payloadCiphertext"], sym, aad).decode())
    assert opened == {"text": "secret reply"}


@requires_relay
@pytest.mark.asyncio
async def test_phone_sealed_event_is_opened_by_agent(monkeypatch, tmp_path):
    """Phone seals an event to the agent pubkey; the adapter opens it."""
    adapter, agent_priv = _e2e_adapter(monkeypatch, tmp_path)
    agent_pub = adapter._relay_public_key_base64()

    # Phone-side seal (mirrors iOS HermesService): wrap to the AGENT pubkey.
    event_id = "evt_sealed_1"
    aad = _burnbar._gateway_event_aad("uid-1", "client-1", event_id)
    sym = relay_e2ee.generate_symmetric_key()
    payload = json.dumps({"text": "open me", "senderDisplayName": "Phone", "threadId": "t1"}).encode()
    payload_ct = relay_e2ee.seal_to_base64(payload, sym, aad)
    wrapped = relay_e2ee.wrap_symmetric_key(sym, agent_pub, aad)

    received = []

    async def capture(event):
        received.append(event)

    adapter.handle_message = capture
    await adapter._handle_burnbar_event(
        {
            "id": event_id,
            "destinationId": "burnbar:home",
            "senderId": "burnbar-user",
            "relayEncryption": _burnbar.RELAY_ENCRYPTION,
            "relayEnvelope": {
                "payloadCiphertext": payload_ct,
                "wrappedKey": wrapped,
                "relayEncryption": _burnbar.RELAY_ENCRYPTION,
                "relayKeyVersion": _burnbar.RELAY_KEY_VERSION,
            },
        }
    )

    assert len(received) == 1
    assert received[0].text == "open me"
    assert received[0].source.user_name == "Phone"
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
    client = _RecordingClient(
        post_responses={
            "/attachments/init": _FakeResponse(
                {"attachment": {"id": "att_e2e"}, "uploadURL": "https://signed.example/put"}
            ),
            "/messages": _FakeResponse({"message": {"id": "m_att"}}),
        }
    )
    adapter._client = client

    result = await adapter.send_document("burnbar:home", str(f), caption="")
    assert result.success is True

    # init carried a sealed envelope, NOT a plaintext fileName.
    _, init_body = next((u, b) for (u, b) in client.posts if u.endswith("/attachments/init"))
    assert "fileName" not in init_body
    env = init_body["relayEnvelope"]
    attachment_id = env["attachmentId"]

    # Uploaded body is ciphertext (not the raw PNG bytes).
    upload_url, uploaded, _hdrs = client.puts[0]
    assert uploaded != b"\x89PNG-binary-body"

    # Phone unwraps the body key with the attachment-KEY AAD, then opens the
    # manifest (payloadCiphertext) with the MANIFEST AAD and the body with the
    # BODY AAD — distinct labels so the relay cannot swap one slot for the other.
    key_aad = _burnbar._gateway_attachment_key_aad("uid-1", "client-1", attachment_id)
    manifest_aad = _burnbar._gateway_attachment_manifest_aad("uid-1", "client-1", attachment_id)
    body_aad = _burnbar._gateway_attachment_body_aad("uid-1", "client-1", attachment_id)
    assert manifest_aad != body_aad  # distinct slot binding
    body_key = relay_e2ee.unwrap_symmetric_key(env["wrappedKey"], phone_priv, key_aad)
    manifest = json.loads(relay_e2ee.open_base64(env["payloadCiphertext"], body_key, manifest_aad).decode())
    assert manifest["fileName"] == "diagram.png"
    assert manifest["byteCount"] == len(b"\x89PNG-binary-body")
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
    """The gateway AAD bytes match the locked CONTRACT prefix verbatim."""
    assert _burnbar._gateway_event_aad("u", "c", "e") == b"OpenBurnBar-HermesRelay-v1|gatewayEvent|u|c|e"
    assert _burnbar._gateway_message_aad("u", "c", "m") == b"OpenBurnBar-HermesRelay-v1|gatewayMessage|u|c|m"
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
    assert (
        _burnbar._gateway_model_switch_aad("u", "c", "e")
        == b"OpenBurnBar-HermesRelay-v1|gatewayModelSwitch|u|c|e"
    )
    # Manifest vs body vs key vs event are all DISTINCT labels (anti-swap).
    labels = {
        _burnbar._gateway_event_aad("u", "c", "a"),
        _burnbar._gateway_attachment_manifest_aad("u", "c", "a"),
        _burnbar._gateway_attachment_body_aad("u", "c", "a"),
        _burnbar._gateway_attachment_key_aad("u", "c", "a"),
        _burnbar._gateway_model_switch_aad("u", "c", "a"),
    }
    assert len(labels) == 5


# ---------------------------------------------------------------------------
# F. Codex security findings (peer-key pinning, fail-closed, standalone,
#    persistence, replay, attachment-AAD, model_switch sealing)
# ---------------------------------------------------------------------------
def _no_persist(monkeypatch):
    """Stop _pin_peer_public_key from writing the real ~/.hermes/.env in tests."""
    import hermes_cli.config as _cfg

    monkeypatch.setattr(_cfg, "save_env_value", lambda *a, **k: None, raising=False)


# --- Finding 1: peer-key pinning (TOFU + reject post-pairing change) --------
@requires_relay
def test_peer_key_pins_once_then_rejects_a_changed_key(monkeypatch, tmp_path):
    """TOFU: first peer key is pinned; a *different* later key is refused (MITM)."""
    _no_persist(monkeypatch)
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path)  # no peer pinned yet
    assert adapter._peer_public_key is None

    first = relay_e2ee.generate_private_key().public_key_base64()
    second = relay_e2ee.generate_private_key().public_key_base64()

    # First key wins (trust-on-first-use).
    assert adapter._pin_peer_public_key("burnbar:home", first, source="state") is True
    assert adapter._peer_public_key == first

    # A different key arriving afterwards is rejected and does NOT overwrite.
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
    """A sealed event carrying a DIFFERENT senderPublicKey must not rotate the pin."""
    _no_persist(monkeypatch)
    phone_priv = relay_e2ee.generate_private_key()
    pinned = phone_priv.public_key_base64()
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path, peer_public_key=pinned)
    agent_pub = adapter._relay_public_key_base64()

    event_id = "evt_sub_key"
    aad = _burnbar._gateway_event_aad("uid-1", "client-1", event_id)
    sym = relay_e2ee.generate_symmetric_key()
    payload_ct = relay_e2ee.seal_to_base64(json.dumps({"text": "hi"}).encode(), sym, aad)
    wrapped = relay_e2ee.wrap_symmetric_key(sym, agent_pub, aad)
    attacker_key = relay_e2ee.generate_private_key().public_key_base64()

    received = []
    adapter.handle_message = lambda e: received.append(e) or _noop()
    await adapter._handle_burnbar_event(
        {
            "id": event_id,
            "destinationId": "burnbar:home",
            "senderPublicKey": attacker_key,  # adversarial field
            "relayEnvelope": {"payloadCiphertext": payload_ct, "wrappedKey": wrapped},
        }
    )
    # Event opens (it was sealed to us) but the pinned key is NOT replaced.
    assert adapter._peer_public_key == pinned


# --- Finding 2: fail-closed (refuse plaintext, never downgrade) -------------
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


# --- Finding 3: standalone bypass (seal or refuse on a paired link) ---------
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
    sym = relay_e2ee.unwrap_symmetric_key(
        env["wrappedKey"], phone_priv,
        _burnbar._gateway_message_aad("uid-s", "client-s", env["messageId"]),
    )
    opened = json.loads(
        relay_e2ee.open_base64(
            env["payloadCiphertext"], sym,
            _burnbar._gateway_message_aad("uid-s", "client-s", env["messageId"]),
        ).decode()
    )
    assert opened == {"text": "standalone secret"}


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


# --- Finding 4: key persistence (minted key survives reload) ----------------
@requires_relay
def test_relay_identity_persists_and_survives_reload(monkeypatch, tmp_path):
    """A freshly minted agent key is persisted and reloads to the SAME identity."""
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


# --- Finding 5: replay (duplicate event id dropped before handle_message) ---
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


def test_seen_event_id_cache_is_bounded(monkeypatch, tmp_path):
    """The replay cache never grows past MAX_SEEN_EVENT_IDS."""
    adapter = _legacy_adapter(monkeypatch, tmp_path)
    monkeypatch.setattr(_burnbar, "MAX_SEEN_EVENT_IDS", 8)
    for i in range(50):
        assert adapter._event_already_seen(f"id-{i}") is False
    assert len(adapter._seen_event_ids) <= 8
    # The most recently seen id is still considered a duplicate.
    assert adapter._event_already_seen("id-49") is True


# --- Finding 7: model_switch must be sealed on E2E links --------------------
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
    adapter, _agent = _e2e_adapter(monkeypatch, tmp_path)
    agent_pub = adapter._relay_public_key_base64()
    received = []

    async def capture(event):
        received.append(event)

    adapter.handle_message = capture
    adapter._publish_runtime_status = lambda *a, **k: _noop()

    event_id = "evt_ms_sealed"
    aad = _burnbar._gateway_model_switch_aad("uid-1", "client-1", event_id)
    sym = relay_e2ee.generate_symmetric_key()
    payload_ct = relay_e2ee.seal_to_base64(json.dumps({"modelId": "anthropic/claude"}).encode(), sym, aad)
    wrapped = relay_e2ee.wrap_symmetric_key(sym, agent_pub, aad)
    await adapter._handle_burnbar_event(
        {
            "id": event_id,
            "kind": "model_switch",
            "destinationId": "burnbar:home",
            "relayEnvelope": {"payloadCiphertext": payload_ct, "wrappedKey": wrapped},
        }
    )
    assert received and received[0].text == "/model anthropic/claude"


@requires_relay
def test_seal_model_switch_round_trip(monkeypatch, tmp_path):
    """seal_model_switch produces an envelope the peer opens under the model-switch AAD."""
    phone_priv = relay_e2ee.generate_private_key()
    adapter, _agent = _e2e_adapter(
        monkeypatch, tmp_path, peer_public_key=phone_priv.public_key_base64()
    )
    env = adapter._sealer.seal_model_switch(destination_id="burnbar:home", model_id="openai/gpt")
    aad = _burnbar._gateway_model_switch_aad("uid-1", "client-1", env["eventId"])
    sym = relay_e2ee.unwrap_symmetric_key(env["wrappedKey"], phone_priv, aad)
    opened = json.loads(relay_e2ee.open_base64(env["payloadCiphertext"], sym, aad).decode())
    assert opened == {"modelId": "openai/gpt"}
